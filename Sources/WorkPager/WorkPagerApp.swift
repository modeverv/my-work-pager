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
        }.defaultSize(width: 448, height: 440)
        .windowResizability(.contentSize)
        Settings { PagerSettingsView(model: model).equatable() }
        Window("カメラ検出デバッグ", id: "camera-debug") {
            CameraDebugView(model: model)
                .onAppear { model.setCameraDebugVisible(true) }
                .onDisappear { model.setCameraDebugVisible(false) }
        }.defaultSize(width: 780, height: 680)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("WORK PAGER").font(.headline).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape").font(.title3) }
                    .buttonStyle(.plain).help("設定を開く（⌘,）")
                    .accessibilityLabel("設定を開く")
            }
            VStack(spacing: 12) {
                Text(model.armed ? "ARMED" : "DISARMED")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(model.armed ? Color.orange : Color.secondary)
                Button(model.armed ? "DISARM" : "ARM") { model.toggleArm() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(model.armed ? .orange : .accentColor)
                    .accessibilityIdentifier("armButton")
                if model.settings.autoMode {
                    Text(model.autoController.overridden ? "AUTO: OVERRIDDEN" : "AUTO: CAMERA")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    if model.autoController.overridden { Button("Resume Auto") { model.resumeAuto() } }
                } else {
                    Text("MANUAL").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label(inputSummary, systemImage: "waveform").font(.callout)
                Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
                if model.capturing {
                    HStack {
                        ProgressView(value: max(0, min(1, (model.level + 60) / 60)))
                        Text("\(model.level, specifier: "%.1f") dBFS").font(.caption).monospacedDigit()
                    }
                }
                if model.settings.autoMode {
                    Label(model.cameraStatus, systemImage: "camera").font(.callout)
                    if let present = model.autoController.presence {
                        Text("\(present ? "在席" : "不在")継続 \(Int(model.stableDuration))秒 / \(Int(present ? model.settings.disarmDelay : model.settings.armDelay))秒")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if model.cameraStatus.contains("切り替え") || model.cameraStatus.contains("エラー") {
                    Text(model.cameraStatus).font(.caption).foregroundStyle(.orange)
                }
                if model.learning || model.template == nil {
                    Text(model.learnStatus).font(.caption).foregroundStyle(.secondary)
                }
                Label(model.notificationStatus, systemImage: "bell").font(.callout)
                if let date = model.lastDetection {
                    Text("最終検出 \(date.formatted(date: .omitted, time: .standard)) ・スコア \(model.lastScore, specifier: "%.3f")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(24).frame(width: 400)
    }
    private var inputSummary: String {
        guard let device = model.selectedDevice else { return "入力デバイス未選択・未接続" }
        let channel = device.channels.indices.contains(model.settings.channel) ? device.channels[model.settings.channel] : "チャンネル未選択"
        return "\(device.name) / \(channel)"
    }
}
