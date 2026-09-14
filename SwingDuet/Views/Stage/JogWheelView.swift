import SwiftUI

/// 回転量をコマ送りへ変換するジョグホイール。加速と反転の規則は JogRotation が持つ。
/// 触覚はシーク完了を待たず、指の操作時点で返す。待つと高速操作で映像の遅延を触覚にも感じるため。
struct JogWheelView: View {
    let controller: PlaybackController
    /// 外径（pt）。帯の幅と再生ボタンはこれに比例する（132 で帯 32・再生 52。横画面は 96 に縮める）
    var diameter: CGFloat = 132

    /// 1 周のコマ数（30fps の動画なら 1 周 = 1 秒）
    private static let framesPerTurn = 30
    private static let degreesPerFrame = 360.0 / Double(framesPerTurn)
    /// 帯の左右のタップ領域（中心からの角度 ±60°）。`cos` がこの値以上なら右、以下の負なら左
    private static let tapZoneCosine = 0.5

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var rotation = JogRotation(degreesPerDetent: degreesPerFrame)
    // 触覚のトリガー。値が変わるたびに 1 回鳴る
    @State private var ticks = 0
    @State private var bumps = 0
    /// ループ範囲の端に当たっている。true になった瞬間だけ鳴らす（当たり続けても鳴らし続けない）
    @State private var atEnd = false

    private var bandWidth: CGFloat { diameter * 32 / 132 }
    private var playDiameter: CGFloat { diameter * 52 / 132 }

    var body: some View {
        ZStack {
            band
            playButton
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - 帯

    private var band: some View {
        Band(width: bandWidth)
            .fill(.quaternary, style: FillStyle(eoFill: true))
            .overlay(marks)
            .contentShape(Band(width: bandWidth), eoFill: true)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let detents = rotation.update(angle: angle(of: value.location), at: value.time)
                        if detents != 0 { step(detents * rotation.framesPerDetent) }
                    }
                    .onEnded { value in
                        // 回さずに離したらタップ。左右のタップ領域なら ±1 コマ
                        let moved = hypot(value.translation.width, value.translation.height)
                        if abs(rotation.totalDegrees) < Self.degreesPerFrame / 2, moved < 10 {
                            let cosine = cos(angle(of: value.startLocation))
                            if cosine <= -Self.tapZoneCosine { step(-1) } else if cosine >= Self.tapZoneCosine { step(1) }
                        }
                        rotation.end()
                    })
            .sensoryFeedback(.selection, trigger: ticks)
            .sensoryFeedback(.impact(weight: .medium), trigger: bumps)
            .sensoryFeedback(.impact(weight: .heavy), trigger: atEnd) { _, hit in hit }
            // ギアは画面に出さず、上がった瞬間の触覚だけで伝える（戻るのは離す・止める・逆回転なので鳴らさない）
            .sensoryFeedback(.increase, trigger: rotation.framesPerDetent) { old, new in new > old }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("コマ送り")
            // NOTE: `commonTime` を body で読むと再生中に毎 tick 描き直されるので、読み上げが要る VoiceOver のときだけ読む
            .accessibilityValue(voiceOverEnabled ? String(format: "%.2f 秒", controller.commonTime) : "")
            .accessibilityHint("上下にスワイプで 1 コマ")
            .accessibilityAdjustableAction { direction in
                step(direction == .increment ? 1 : -1)
            }
            .accessibilityIdentifier("transport.jog")
    }

    /// 帯の外縁の刻み（1 コマごと。回しても動かない）と、左右のタップ領域の印
    private var marks: some View {
        ZStack {
            ForEach(0..<Self.framesPerTurn, id: \.self) { i in
                Capsule()
                    .fill(.secondary)
                    .frame(width: 1.5, height: 6)
                    .offset(y: -(diameter / 2 - 6))
                    .rotationEffect(.degrees(Double(i) * Self.degreesPerFrame))
            }
            HStack {
                Image(systemName: "backward.frame.fill")
                Spacer()
                Image(systemName: "forward.frame.fill")
            }
            .font(.system(size: bandWidth * 0.36))
            .foregroundStyle(.secondary)
            .padding(.horizontal, bandWidth * 0.32)
        }
    }

    /// 帯の上の点の、中心から見た角度（ラジアン。画面座標は y が下向きなので時計回りが正）
    private func angle(of point: CGPoint) -> Double {
        atan2(point.y - diameter / 2, point.x - diameter / 2)
    }

    /// frames コマ動かし、結果に応じた触覚を鳴らす
    private func step(_ frames: Int) {
        let before = controller.commonTime
        controller.stepFrame(by: frames)
        let after = controller.commonTime
        atEnd = after == before
        guard !atEnd else { return }
        // 同期しないときはトップ / インパクトの位置が側ごとに違うので、どちらの側のものを通過しても鳴らす
        let crossed = VideoSide.allCases.contains { side in
            [SwingPhase.top, .impact].contains { phase in
                let t = controller.sync.commonTime(of: phase, for: side)
                return (before >= t) != (after >= t)
            }
        }
        if crossed { bumps += 1 } else { ticks += 1 }
    }

    // MARK: - 再生ボタン

    private var playButton: some View {
        Button {
            controller.togglePlay()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: playDiameter))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isPlaying ? "一時停止" : "再生")
        .accessibilityIdentifier("transport.play")
    }
}

/// ドーナツ形（外周の円から幅 `width` の帯）。塗りと当たり判定は even-odd で穴を抜く
private struct Band: Shape {
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        path.addPath(Path(ellipseIn: rect.insetBy(dx: width, dy: width)))
        return path
    }
}
