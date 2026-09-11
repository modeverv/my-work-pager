import SwiftUI
import AVFoundation
import WorkPagerCore

@MainActor final class AppModel: ObservableObject {
    @Published var settings = Preferences.load() { didSet { settings.save() } }
    @Published var devices: [InputDevice] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published private(set) var armed = false
    @Published private(set) var capturing = false
    @Published private(set) var learning = false
    @Published private(set) var previewing = false
    @Published private(set) var level = -90.0
    @Published private(set) var score = 0.0
    @Published private(set) var lastDetection: Date?
    @Published private(set) var lastScore = 0.0
    @Published private(set) var template: SoundTemplate?
    @Published var audioStatus = "入力停止"
    @Published var learnStatus = "未学習"
    @Published private(set) var cameraDebugFrame: CameraDebugFrame?
    private var debugVisible = false
    private var debugGeneration = UUID()
    @Published var cameraStatus = "カメラ停止"
    @Published var notificationStatus = "未送信"
    @Published private(set) var sending = false
    @Published var topic = ""
    @Published var secretStatus = ""
    @Published private(set) var autoController = AutoArmController()
    @Published private(set) var stableDuration = 0.0
    private let audio = AudioCapture()
    private let camera = CameraPresence()
    private let ntfy = NtfyClient()
    private var gate = AlertGate()
    private var generation = UUID()
    private var cameraGeneration = UUID()
    private var lastPresenceSample: TimeInterval?
    private var cameraFailureMessage: String?
    private var didDiscoverDevices = false
    private var learningTimeout: Task<Void, Never>?
    private var previewTimeout: Task<Void, Never>?
    private var deviceTimer: Timer?

    init() {
        do { template = try LocalStore.loadTemplate(); if let template { learnStatus = String(format: "学習済み %.2f秒", Double(template.samples.count) / template.sampleRate) } }
        catch { learnStatus = error.localizedDescription }
        topic = SecretStore.load() ?? ""
        refreshDevices()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshDevices() } }
        if settings.autoMode { startCamera() }
    }
    var selectedDevice: InputDevice? { devices.first { $0.uid == settings.deviceUID } }
    func refreshDevices() {
        let latest = AudioDevices.inputs()
        if latest != devices { devices = latest }
        let latestCameras = CameraPresence.devices()
        if latestCameras.map(\.uniqueID) != cameras.map(\.uniqueID) { cameras = latestCameras }
        if !didDiscoverDevices, settings.deviceUID.isEmpty, let first = devices.first(where: { $0.name.localizedCaseInsensitiveContains("Fireface") }) ?? devices.first {
            settings.deviceUID = first.uid; settings.channel = 0
        }
        if !didDiscoverDevices, settings.cameraID.isEmpty, let first = cameras.first { settings.cameraID = first.uniqueID }
        didDiscoverDevices = true
        if capturing && selectedDevice == nil { audioFailed("選択した入力が切断されました") }
    }
    func inputChanged() {
        score = 0
        if let device = selectedDevice, !device.channels.indices.contains(settings.channel) { settings.channel = 0 }
        stopAudio(); if armed || learning || previewing { ensureAudio() }
    }
    func toggleArm() {
        if settings.autoMode { autoController.override() }
        setArmed(!armed)
    }
    private func setArmed(_ value: Bool) {
        guard armed != value else { return }
        armed = value; stopAudio()
        if value { cancelLearning(); previewing = false; previewTimeout?.cancel(); ensureAudio() }
    }
    func preview() {
        if previewing { previewing = false; previewTimeout?.cancel(); if !armed && !learning { stopAudio() }; return }
        previewing = true; ensureAudio()
        previewTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.previewing = false; if !self.armed && !self.learning { self.stopAudio() }
        }
    }
    func learn() {
        if learning { cancelLearning(); return }
        if settings.autoMode { autoController.override() }
        setArmed(false)
        stopAudio()
        learning = true; learnStatus = "Slackの通知音を1回鳴らしてください（15秒以内）"
        ensureAudio()
        learningTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.learning else { return }
            self.cancelLearning(); self.learnStatus = "音を検出できませんでした。入力・チャンネルを確認してください。"
        }
    }
    private func cancelLearning() {
        learningTimeout?.cancel(); learningTimeout = nil
        if learning { learning = false; learnStatus = template == nil ? "未学習" : "学習済み（前回のデータを保持）" }
        if !armed && !previewing { stopAudio() }
    }
    private func ensureAudio() {
        guard !capturing else { return }
        let requestID = generation
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard requestID == generation, !capturing, armed || learning || previewing else { return }
            guard allowed else { audioFailed("音声入力の許可が必要です。システム設定 → プライバシーとセキュリティ → マイク"); return }
            guard let device = selectedDevice else { audioFailed("入力デバイスを選択してください"); return }
            configureAudioCallbacks(for: requestID)
            do { try audio.start(device: device, channel: settings.channel); capturing = true; audioStatus = "入力中: \(device.name)" }
            catch { audioFailed(error.localizedDescription) }
        }
    }
    private func configureAudioCallbacks(for captureID: UUID) {
        audio.onSamples = { [weak self] level, events in
            Task { @MainActor [weak self] in
                guard let self, self.capturing, captureID == self.generation else { return }
                self.level = max(-90, 20 * log10(max(Double(level), 0.000001)))
                for event in events { self.process(event) }
            }
        }
        audio.onFailure = { [weak self] message in Task { @MainActor in guard let self, captureID == self.generation else { return }; self.audioFailed(message) } }
        audio.onDiscontinuity = { [weak self] in Task { @MainActor in guard let self, captureID == self.generation else { return }; self.audioStatus = "入力欠落: 候補を破棄しました" } }
    }
    private func stopAudio() { generation = UUID(); audio.stop(); capturing = false; level = -90; audioStatus = "入力停止" }
    private func audioFailed(_ message: String) {
        if settings.autoMode { autoController.override() }
        armed = false; previewing = false; learning = false
        learningTimeout?.cancel(); previewTimeout?.cancel(); stopAudio(); audioStatus = message
    }
    private func process(_ event: [Float]) {
        if learning {
            let learned = SoundTemplate(samples: event)
            guard learned.isValid else { learnStatus = "短すぎる音です。もう一度通知音を鳴らしてください。"; return }
            do { try LocalStore.save(learned); template = learned; cancelLearning(); learnStatus = String(format: "学習成功 %.2f秒・ローカル保存済み", Double(event.count) / 12000) }
            catch { cancelLearning(); learnStatus = "保存失敗: \(error.localizedDescription)" }
            return
        }
        guard let template else { return }
        let current = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) { SignalMatcher.score(reference: template.samples, candidate: event) }.value
            guard current == generation else { return }
            score = result
            if gate.accept(armed: armed && !sending, score: result, threshold: settings.threshold, now: ProcessInfo.processInfo.systemUptime, cooldown: settings.cooldown) {
                lastDetection = Date(); lastScore = result; sendNotification(automatic: true)
            }
        }
    }
    func setCameraDebugVisible(_ visible: Bool) {
        debugVisible = visible
        configureCameraDebug()
    }
    private func configureCameraDebug() {
        debugGeneration = UUID(); let current = debugGeneration
        cameraDebugFrame = nil
        guard debugVisible, settings.autoMode else { camera.setDebugHandler(nil); return }
        camera.setDebugHandler { [weak self] frame in
            Task { @MainActor in
                guard let self, self.debugVisible, self.settings.autoMode, current == self.debugGeneration,
                      ProcessInfo.processInfo.systemUptime - frame.capturedAt < 2 else { return }
                self.cameraDebugFrame = frame
            }
        }
    }
    func modeChanged() {
        autoController.resume(); stableDuration = 0
        configureCameraDebug()
        if settings.autoMode { startCamera() } else { cameraGeneration = UUID(); camera.stop(); cameraStatus = cameraFailureMessage ?? "手動モード" }
    }
    func resumeAuto() { autoController.resume(); stableDuration = 0 }
    func cameraChanged() { autoController.reset(); stableDuration = 0; if settings.autoMode { startCamera() } }
    func delayChanged() { autoController.reset(); stableDuration = 0 }
    private func startCamera() {
        configureCameraDebug()
        cameraGeneration = UUID(); let current = cameraGeneration
        lastPresenceSample = nil; cameraFailureMessage = nil
        cameraStatus = "カメラ起動中"
        let onPresence: (Bool) -> Void = { [weak self] present in
            let sampledAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
            guard let self, self.settings.autoMode, current == self.cameraGeneration else { return }
            guard ProcessInfo.processInfo.systemUptime - sampledAt < 2 else { self.autoController.reset(); return }
            if let last = self.lastPresenceSample, sampledAt - last > 2 { self.autoController.reset() }
            self.lastPresenceSample = sampledAt
            let now = sampledAt
            let next = self.autoController.observe(present: present, at: now, armDelay: self.settings.armDelay, disarmDelay: self.settings.disarmDelay)
            self.stableDuration = self.autoController.stableDuration(at: now)
            self.cameraStatus = present ? "● PRESENT / 在席" : "○ ABSENT / 不在"
            if let next { self.setArmed(next) }
        } }
        let onFailure: (String) -> Void = { [weak self] message in Task { @MainActor in
            guard let self, current == self.cameraGeneration else { return }
            self.cameraFallback(message)
        } }
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard settings.autoMode, current == cameraGeneration else { return }
            guard allowed else { cameraFallback("カメラ権限がありません。手動モードに切り替えました。"); return }
            camera.start(id: settings.cameraID, onPresence: onPresence, onFailure: onFailure)
        }
    }
    private func cameraFallback(_ message: String) {
        cameraFailureMessage = message
        cameraGeneration = UUID(); camera.stop(); settings.autoMode = false
        configureCameraDebug()
        autoController.resume(); stableDuration = 0; cameraStatus = message
        // Preserve the explicit ARM state when the camera becomes unavailable.
    }
    func saveTopic() {
        do { _ = try NtfyRequest.make(server: settings.server, topic: topic); try SecretStore.save(topic); secretStatus = "Keychainに保存済み" }
        catch { secretStatus = "保存失敗: \(error.localizedDescription)" }
    }
    func generateTopic() { topic = "work-pager-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(); saveTopic() }
    func sendNotification(automatic: Bool = false) {
        guard !sending else { return }
        sending = true; notificationStatus = "送信中"
        let server = settings.server, secret = topic
        let capturedGeneration = generation
        Task {
            if automatic && (!armed || generation != capturedGeneration) { sending = false; notificationStatus = "送信中止（DISARMまたは入力変更）"; return }
            notificationStatus = await ntfy.send(server: server, topic: secret); sending = false
        }
    }
    func shutdown() { deviceTimer?.invalidate(); learningTimeout?.cancel(); previewTimeout?.cancel(); stopAudio(); camera.stop() }
}
