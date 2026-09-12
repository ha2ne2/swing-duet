import SwiftUI

/// 再生操作パネル：フェーズジャンプ / ジョグホイール（再生・停止とコマ送り）/ 速度 / ループ
struct TransportControlsView: View {
    @Bindable var controller: PlaybackController
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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

            // ループ・ジョグホイール（中央が再生）・速度。横画面はペインの高さが無いのでホイールを小さくする
            HStack(spacing: 22) {
                loopMenu
                JogWheelView(controller: controller, diameter: verticalSizeClass == .compact ? 96 : 132)
                speedButton
            }
            .buttonStyle(.plain)
        }
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
                // つまみで動かした範囲は区間の項目に一致しないので、いまの範囲を項目として足す（Picker は選択が項目に無いと未定義）
                if let range = controller.loop.range, range.segment == nil {
                    Text("\(range.start.label) 〜 \(range.end.label)").tag(controller.loop)
                }
                Text("ループしない").tag(PlaybackController.LoopMode.off)
            }
        } label: {
            Image(systemName: controller.loop.range == nil ? "repeat" : "repeat.1")
                .font(.title3)
                .foregroundStyle(controller.loop == .off ? Color.secondary : Color.accentColor)
        }
        // NOTE: 画面下端のボタンからメニューが上に開くと iOS は項目を逆順（先頭がボタン側）に並べる。
        //       スイング全体 → 各区間 → ループしない の宣言順で見せたいので固定する
        .menuOrder(.fixed)
        .accessibilityLabel("ループ範囲")
    }
}
