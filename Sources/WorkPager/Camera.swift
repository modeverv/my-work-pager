import Foundation
import AVFoundation
import Vision
import CoreImage

final class CameraPresence: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "WorkPager.camera")
    private let session = AVCaptureSession()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var debugHandler: ((CameraDebugFrame) -> Void)?
    func setDebugHandler(_ handler: ((CameraDebugFrame) -> Void)?) {
        queue.async { [weak self] in self?.debugHandler = handler }
    }
    private var lastAnalysis = 0.0
    private var lastFrame = 0.0
    private var watchdog: DispatchSourceTimer?
    private var observation: NSObjectProtocol?
    var onPresence: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }
    func start(id: String, onPresence: @escaping (Bool) -> Void, onFailure: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.onPresence = onPresence; self.onFailure = onFailure
            guard let device = Self.devices().first(where: { $0.uniqueID == id }) else { self.onFailure?("カメラが見つかりません。手動操作に切り替えました。"); return }
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .vga640x480
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { self.session.commitConfiguration(); self.onFailure?("カメラを使用できません"); return }
                self.session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); self.onFailure?("カメラ出力を使用できません"); return }
                self.session.addOutput(output)
                self.session.commitConfiguration()
                self.lastAnalysis = 0
                self.lastFrame = ProcessInfo.processInfo.systemUptime
                self.observation = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: self.session, queue: nil) { [weak self] _ in self?.onFailure?("カメラ接続エラー。手動操作に切り替えました。") }
                self.session.startRunning()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 2, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self, ProcessInfo.processInfo.systemUptime - self.lastFrame > 4 else { return }
                    self.stopOnQueue(); self.onFailure?("カメラ映像が停止しました。手動操作に切り替えました。")
                }
                self.watchdog = timer; timer.resume()
            } catch { self.session.commitConfiguration(); self.onFailure?("カメラを開始できません: \(error.localizedDescription)") }
        }
    }
    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }
    private func stopOnQueue() {
        watchdog?.cancel(); watchdog = nil
        if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        lastFrame = now
        guard now - lastAnalysis >= 0.5, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        do {
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = true
            try VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
            let people = (request.results ?? []).map { CameraDebugPerson(bounds: $0.boundingBox, confidence: $0.confidence) }
            onPresence?(people.contains(where: { $0.countsAsPresent }))
            if let debugHandler {
                let input = CIImage(cvPixelBuffer: pixels)
                if let image = imageContext.createCGImage(input, from: input.extent) {
                    debugHandler(CameraDebugFrame(image: image, people: people, capturedAt: now))
                }
            }
        } catch { onFailure?("人物検出エラー。手動操作に切り替えました。") }
    }
}
