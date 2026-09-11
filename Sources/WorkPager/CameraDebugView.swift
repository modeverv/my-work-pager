import SwiftUI

struct CameraDebugPerson {
    let bounds: CGRect
    let confidence: Float
    var countsAsPresent: Bool { confidence >= 0.5 }
}

struct CameraDebugFrame {
    let image: CGImage
    let people: [CameraDebugPerson]
    let capturedAt: TimeInterval
}

struct CameraDebugView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("カメラが人物として検出している範囲").font(.title2.bold())
            Text(model.cameras.first(where: { $0.uniqueID == model.settings.cameraID })?.localizedName ?? "カメラ未選択")
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let frame = model.cameraDebugFrame, ProcessInfo.processInfo.systemUptime - frame.capturedAt < 3 {
                    Canvas { context, size in
                        context.draw(Image(decorative: frame.image, scale: 1), in: CGRect(origin: .zero, size: size))
                        for (index, person) in frame.people.enumerated() {
                            // Vision coordinates start at bottom-left; Canvas starts at top-left.
                            let rect = CGRect(x: person.bounds.minX * size.width,
                                              y: (1 - person.bounds.maxY) * size.height,
                                              width: person.bounds.width * size.width,
                                              height: person.bounds.height * size.height)
                            let color: Color = person.countsAsPresent ? .green : .yellow
                            context.stroke(Path(rect), with: .color(color), lineWidth: 3)
                            let label = Text("人物\(index + 1)  \(Int(person.confidence * 100))%  \(person.countsAsPresent ? "在席判定の対象" : "しきい値未満")")
                                .font(.system(size: 14, weight: .bold)).foregroundColor(.black)
                            let labelRect = CGRect(x: max(0, min(size.width - 240, rect.minX)), y: max(0, rect.minY - 24), width: 240, height: 24)
                            context.fill(Path(labelRect), with: .color(color.opacity(0.95)))
                            context.draw(label, at: CGPoint(x: labelRect.minX + 5, y: labelRect.midY), anchor: .leading)
                        }
                    }
                    .aspectRatio(CGFloat(frame.image.width) / CGFloat(frame.image.height), contentMode: .fit)
                    .accessibilityLabel("カメラ映像、在席判定の対象は\(frame.people.filter(\.countsAsPresent).count)人")
                    Text("検出 \(frame.people.count)人 / 在席判定の対象 \(frame.people.filter(\.countsAsPresent).count)人（信頼度50%以上）")
                        .font(.headline).monospacedDigit()
                } else {
                    Rectangle().fill(.black).aspectRatio(4.0 / 3, contentMode: .fit)
                        .overlay { Text(model.settings.autoMode ? "映像待機中 / 更新が途切れると映像を隠します" : "Auto (Camera)を選択すると映像を表示します")
                            .foregroundStyle(.white).multilineTextAlignment(.center).padding() }
                }
            }
            HStack {
                Text(model.cameraStatus)
                Spacer()
                Text(model.armed ? "ARMED" : "DISARMED").bold()
            }
            if model.settings.autoMode {
                Text(model.autoController.overridden ? "AUTO: OVERRIDDEN — 手動操作が優先されています" : "継続 \(Int(model.stableDuration))秒 / 不在\(Int(model.settings.armDelay))秒でARM・在席\(Int(model.settings.disarmDelay))秒でDISARM")
                    .font(.callout)
            }
            Text("緑枠が1人でもあれば在席と判定します。本人の識別や距離による除外は行っていないため、奥のソファにいる人も対象になります。")
                .font(.callout).foregroundStyle(.secondary)
            Text("映像と検出枠は同じ解析フレーム（約2回/秒）。左右反転なし。表示用の最新1枚だけをメモリに保持し、窓を閉じると破棄します。保存・送信はしません。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 600, minHeight: 540)
    }
}
