import Foundation
import CoreAudio
import AudioToolbox
import WorkPagerCore

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: [String]
}

enum AudioDevices {
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, element: UInt32 = 0, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer { value.deinitialize(count: 1); value.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee as String?
    }
    static func inputs() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var config = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: 0)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &config, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &config, 0, nil, &bytes, raw) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            let count = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard count > 0 else { return nil }
            let channels = (1...count).map { channel -> String in
                if let label = string(id, kAudioObjectPropertyElementName, element: UInt32(channel), scope: kAudioDevicePropertyScopeInput), !label.isEmpty { return "\(channel): \(label)" }
                return "Input \(channel)"
            }
            return InputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)", name: string(id, kAudioObjectPropertyName) ?? "Audio \(id)", channels: channels)
        }
    }
}

struct AudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? { "\(operation) (Core Audio \(status))" }
}

final class AudioCapture {
    private var unit: AudioUnit?
    private var buffers: UnsafeMutableAudioBufferListPointer?
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 262144)
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var lost = false
    private var pendingDrop = false
    private var channel = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "WorkPager.audio-processing", qos: .userInitiated)
    private var resampler = MonoResampler()
    private var extractor = EventExtractor()
    private var rate = 48000.0
    var onSamples: ((Float, [[Float]]) -> Void)?
    var onFailure: ((String) -> Void)?
    var onDiscontinuity: (() -> Void)?
    private var lastBuffer = ProcessInfo.processInfo.systemUptime
    private let maxFrames: UInt32 = 8192

    func start(device: InputDevice, channel: Int) throws {
        stop()
        self.channel = channel
        guard device.channels.indices.contains(channel) else { throw AudioFailure(operation: "入力チャンネルがありません", status: -1) }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw AudioFailure(operation: "AUHAL", status: -1) }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "AUHAL作成")
        unit = created
        guard let unit else { throw AudioFailure(operation: "AUHAL", status: -1) }
        do {
            var one: UInt32 = 1, zero: UInt32 = 0, deviceID = device.id
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "入力有効化")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "出力無効化")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, 4), "入力デバイス設定")
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size), "入力形式取得")
            rate = format.mSampleRate
            let count = UInt32(device.channels.count)
            format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: count, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, size), "Float32形式設定")
            var frames = maxFrames
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, 4), "バッファサイズ設定")
            let allocated = AudioBufferList.allocate(maximumBuffers: Int(count))
            allocated.unsafeMutablePointer.pointee.mNumberBuffers = count
            for i in 0..<Int(count) {
                allocated[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4, mData: UnsafeMutableRawPointer.allocate(byteCount: Int(maxFrames) * 4, alignment: 16))
            }
            buffers = allocated
            var callback = AURenderCallbackStruct(inputProc: { ref, flags, stamp, bus, frames, _ in
                let owner = Unmanaged<AudioCapture>.fromOpaque(ref).takeUnretainedValue()
                return owner.render(flags: flags, stamp: stamp, frames: frames)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "入力コールバック設定")
            try check(AudioUnitInitialize(unit), "音声初期化")
            resampler = MonoResampler(); extractor = EventExtractor()
            readIndex = 0; writeIndex = 0; available = 0; lost = false; pendingDrop = false
            lastBuffer = ProcessInfo.processInfo.systemUptime
            try check(AudioOutputUnitStart(unit), "音声開始")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.drain() }
            self.timer = timer
            timer.resume()
        } catch { stop(); throw error }
    }
    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, stamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, let buffers, frames <= maxFrames else { return kAudio_ParamError }
        for i in buffers.indices { buffers[i].mDataByteSize = frames * 4 }
        let result = AudioUnitRender(unit, flags, stamp, 1, frames, buffers.unsafeMutablePointer)
        guard result == noErr, let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { return result }
        guard lock.try() else { pendingDrop = true; return noErr }
        defer { lock.unlock() }
        if pendingDrop { lost = true; pendingDrop = false }
        lastBuffer = ProcessInfo.processInfo.systemUptime
        if available + Int(frames) > ring.count { lost = true; return noErr }
        for i in 0..<Int(frames) { ring[writeIndex] = data[i]; writeIndex = (writeIndex + 1) % ring.count }
        available += Int(frames)
        return noErr
    }
    private func drain() {
        lock.lock()
        var samples = [Float](); samples.reserveCapacity(available)
        while available > 0 { samples.append(ring[readIndex]); readIndex = (readIndex + 1) % ring.count; available -= 1 }
        let discontinuity = lost; lost = false
        let stalled = ProcessInfo.processInfo.systemUptime - lastBuffer > 3
        lock.unlock()
        if stalled { onFailure?("入力が停止しました。デバイス接続・サンプルレートを確認してください。"); return }
        if discontinuity { extractor = EventExtractor(); resampler = MonoResampler(); onDiscontinuity?(); return }
        guard !samples.isEmpty else { return }
        let level = SignalMatcher.rms(samples)
        let events = extractor.process(resampler.process(samples, rate: rate))
        onSamples?(level, events)
    }
    func stop() {
        if let unit { AudioOutputUnitStop(unit) }
        timer?.cancel(); timer = nil
        queue.sync {}
        if let unit { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil
        if let buffers { for buffer in buffers { buffer.mData?.deallocate() }; buffers.unsafeMutablePointer.deallocate() }
        buffers = nil
    }
    private func check(_ status: OSStatus, _ operation: String) throws { if status != noErr { throw AudioFailure(operation: operation, status: status) } }
    deinit { stop() }
}
