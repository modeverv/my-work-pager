import SwiftUI

final class WorkPagerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled artwork directly so a previously cached generic Dock icon
        // does not survive an in-place update of this locally built app.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

@main struct WorkPagerApp: App {
    @NSApplicationDelegateAdaptor(WorkPagerAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Work Pager", id: "main") {
            ContentView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }.defaultSize(width: 520, height: 800)
        .windowResizability(.contentMinSize)
        Window("カメラ検出デバッグ", id: "camera-debug") {
            CameraDebugView(model: model)
                .onAppear { model.setCameraDebugVisible(true) }
                .onDisappear { model.setCameraDebugVisible(false) }
        }.defaultSize(width: 780, height: 680)
    }
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    Text("WORK PAGER").font(.headline).foregroundStyle(.secondary)
                    Text(model.armed ? "ARMED" : "DISARMED").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(model.armed ? Color.orange : Color.secondary)
                    Button(model.armed ? "DISARM" : "ARM") { model.toggleArm() }
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(model.armed ? .orange : .accentColor)
                        .accessibilityIdentifier("armButton")
                    if model.settings.autoMode {
                        HStack {
                            Text(model.autoController.overridden ? "AUTO: OVERRIDDEN" : "AUTO: CAMERA").font(.caption.bold())
                            if model.autoController.overridden { Button("Resume Auto") { model.resumeAuto() } }
                        }
                    }
                    if let date = model.lastDetection {
                        Text("最終検出 \(date.formatted(date: .omitted, time: .standard)) ・スコア \(model.lastScore, specifier: "%.3f")").font(.caption)
                    }
                }.frame(maxWidth: .infinity).padding(12)
                VStack(alignment: .leading, spacing: 8) {
                    Text("入力").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("デバイス", selection: $model.settings.deviceUID) {
                            Text("選択してください").tag("")
                            ForEach(model.devices) { Text($0.name).tag($0.uid) }
                            if !model.settings.deviceUID.isEmpty && model.selectedDevice == nil { Text("未接続のデバイス").tag(model.settings.deviceUID) }
                        }.onChange(of: model.settings.deviceUID) { model.inputChanged() }
                        Picker("チャンネル", selection: $model.settings.channel) {
                            if let device = model.selectedDevice { ForEach(Array(device.channels.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) } }
                        }.onChange(of: model.settings.channel) { model.inputChanged() }
                        HStack {
                            ProgressView(value: max(0, min(1, (model.level + 60) / 60)))
                            Text("\(model.level, specifier: "%.1f") dBFS").monospacedDigit().frame(width: 90)
                        }
                        HStack {
                            Button(model.previewing ? "入力確認を停止" : "入力を30秒確認") { model.preview() }.disabled(model.armed || model.learning)
                            Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("通知音").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Button(model.learning ? "学習をキャンセル" : "Learn / 学習") { model.learn() }; Spacer(); Text("Match: \(model.score, specifier: "%.3f")").monospacedDigit() }
                        Text(model.learnStatus).font(.caption).textSelection(.enabled)
                        HStack { Text("検出しきい値"); Slider(value: $model.settings.threshold, in: 0.5...1, step: 0.01); Text("\(model.settings.threshold, specifier: "%.2f")").monospacedDigit() }
                        secondsField("クールダウン", value: $model.settings.cooldown, range: 1...3600)
                    }.padding(6)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("ARMモード").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("モード", selection: $model.settings.autoMode) { Text("Manual").tag(false); Text("Auto (Camera)").tag(true) }.pickerStyle(.segmented).onChange(of: model.settings.autoMode) { model.modeChanged() }
                        Picker("カメラ", selection: $model.settings.cameraID) {
                            Text("選択してください").tag("")
                            ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                            if !model.settings.cameraID.isEmpty && !model.cameras.contains(where: { $0.uniqueID == model.settings.cameraID }) { Text("未接続のカメラ").tag(model.settings.cameraID) }
                        }.onChange(of: model.settings.cameraID) { model.cameraChanged() }
                        Text(model.cameraStatus).font(.caption)
                        Button("カメラ映像・検出枠を表示") { openWindow(id: "camera-debug") }
                        if model.settings.autoMode, let present = model.autoController.presence {
                            Text("\(present ? "在席" : "不在")継続: \(Int(model.stableDuration)) / \(Int(present ? model.settings.disarmDelay : model.settings.armDelay))秒").font(.caption).monospacedDigit()
                        }
                        secondsField("不在からARM", value: $model.settings.armDelay, range: 1...600).onChange(of: model.settings.armDelay) { model.delayChanged() }
                        secondsField("在席からDISARM", value: $model.settings.disarmDelay, range: 1...600).onChange(of: model.settings.disarmDelay) { model.delayChanged() }
                    }.padding(6)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("ntfy").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("サーバーURL", text: $model.settings.server)
                        SecureField("秘密のtopic", text: $model.topic)
                        HStack {
                            Button("ランダム生成・保存") { model.generateTopic() }
                            Button("保存") { model.saveTopic() }
                            Button("topicをコピー") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.topic, forType: .string) }.disabled(model.topic.isEmpty)
                        }
                        Text(model.secretStatus).font(.caption)
                        HStack { Button("Send Test Notification") { model.sendNotification() }.disabled(model.sending || model.topic.isEmpty); Text(model.notificationStatus).font(.caption) }
                        Text("送信内容: Work Pager / 仕事PCを確認").font(.caption).foregroundStyle(.secondary)
                    }.textFieldStyle(.roundedBorder).padding(6)
                }
                Text("音声・カメラ画像は外部送信しません。カメラ画像は保存しません。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(20)
        }.frame(minWidth: 480, minHeight: 680)
    }
    private func secondsField(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                .frame(width: 65).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .onChange(of: value.wrappedValue) {
                    if !value.wrappedValue.isFinite { value.wrappedValue = range.lowerBound }
                    else { value.wrappedValue = min(range.upperBound, max(range.lowerBound, value.wrappedValue)) }
                }
            Text("秒").foregroundStyle(.secondary)
        }
    }

}
