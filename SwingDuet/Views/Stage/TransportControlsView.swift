import SwiftUI

/// 再生操作パネル：フェーズジャンプ / コマ送り / 再生・停止 / 速度 / ループ
struct TransportControlsView: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        VStack(spacing: 10) {
            // フェーズへのジャンプ（フィニッシュは終端なので省く）
            HStack(spacing: 8) {
                ForEach([SwingPhase.address, .top, .impact]) { phase in
                    Button {
                        controller.jump(to: phase)
                    } label: {
                        Text(phase.label)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // 再生・コマ送り・ループ
            HStack(spacing: 22) {
                loopMenu

                stepButton(frames: -1, symbol: "backward.frame.fill", label: "1 コマ戻す")

                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }

                stepButton(frames: 1, symbol: "forward.frame.fill", label: "1 コマ進める")

                speedButton
            }
            .buttonStyle(.plain)
        }
    }

    /// コマ送り。押した瞬間に 1 コマ、押しっぱなしで進み続ける
    private func stepButton(frames: Int, symbol: String, label: String) -> some View {
        HoldRepeatButton(
            onPress: { controller.beginStepping(by: frames) },
            onRelease: { controller.endStepping() },
            action: { controller.stepFrame(by: frames) }
        ) {
            Image(systemName: symbol)
                .font(.title3)
        }
        .accessibilityLabel(label)
    }

    /// 再生速度。タップで PlaybackController.speedPresets を巡回する
    private var speedButton: some View {
        let speedText = String(format: "x%.2f", controller.speed)
        return Button {
            controller.cycleSpeed()
        } label: {
            Text(speedText)
                .font(.caption.monospacedDigit())
                .frame(width: 52, height: 30)
                .background(.quaternary, in: Capsule())
                .frame(height: 44)   // タッチ領域
                .contentShape(Rectangle())
        }
        .accessibilityLabel("再生速度")
        .accessibilityValue(speedText)
        .accessibilityHint("タップで切り替え")
    }

    private var loopMenu: some View {
        Menu {
            Picker("ループ範囲", selection: $controller.loop) {
                Text("スイング全体").tag(PlaybackController.LoopMode.all)
                ForEach(SwingSegment.allCases) { segment in
                    Text("\(segment.label)のみ").tag(PlaybackController.LoopMode.segment(segment))
                }
                Text("ループしない").tag(PlaybackController.LoopMode.off)
            }
        } label: {
            Image(systemName: controller.loop.segment == nil ? "repeat" : "repeat.1")
                .font(.title3)
                .foregroundStyle(controller.loop == .off ? Color.secondary : Color.accentColor)
        }
        // NOTE: 画面下端のボタンからメニューが上に開くと iOS は項目を逆順（先頭がボタン側）に並べる。
        //       スイング全体 → 各区間 → ループしない の宣言順で見せたいので固定する
        .menuOrder(.fixed)
        .accessibilityLabel("ループ範囲")
    }
}
