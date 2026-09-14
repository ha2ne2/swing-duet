import SwiftUI

/// 再生操作パネル：フェーズジャンプ / ジョグホイール（再生・停止とコマ送り）/ 速度 / ループ
struct TransportControlsView: View {
    @Bindable var controller: PlaybackController
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(spacing: 10) {
            // フェーズへのジャンプ（フィニッシュは終端なので省く）。同期しないときは押したフェーズで両方を揃え直すので、揃えているものを塗る
            HStack(spacing: 8) {
                ForEach([SwingPhase.address, .top, .impact]) { phase in
                    let isAnchor = controller.syncBasis == .free && controller.sync.anchor == phase
                    Button {
                        controller.jump(to: phase)
                    } label: {
                        Text(phase.label)
                            .capsuleChip(selected: isAnchor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isAnchor ? "ここで揃えている" : "")
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

    /// 再生速度。タップで `PlaybackController.speedPresets` を巡回する
    private var speedButton: some View {
        // プリセットは x1 以下の 1/2^n なので、小数（x1/8 が x0.13）ではなく分数で出す
        let denominator = controller.speed > 0 ? Int((1 / controller.speed).rounded()) : 1
        let (speedText, spokenSpeed) = denominator <= 1
            ? ("x1", "等倍")
            : ("x1/\(denominator)", "\(denominator)分の1の速さ")
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
        .accessibilityValue(spokenSpeed)
        .accessibilityHint("タップで切り替え")
    }

    /// スイング全体より狭い範囲（区間か、つまみで動かした範囲）をループしている
    private var isPartialLoop: Bool {
        controller.loop.map { $0 != .all } ?? false
    }

    private var loopMenu: some View {
        Menu {
            Picker("ループ範囲", selection: $controller.loop) {
                Text("スイング全体").tag(Optional(LoopRange.all))
                ForEach(SwingSegment.allCases) { segment in
                    Text("\(segment.label)のみ").tag(Optional(LoopRange.segment(segment)))
                }
                // つまみで動かした範囲は上の項目に一致しないので、いまの範囲を項目として足す（Picker は選択が項目に無いと未定義）
                if let range = controller.loop, range != .all, range.segment == nil {
                    Text("\(range.start.label) 〜 \(range.end.label)").tag(Optional(range))
                }
                Text("ループしない").tag(LoopRange?.none)
            }
        } label: {
            Image(systemName: isPartialLoop ? "repeat.1" : "repeat")
                .font(.title3)
                .foregroundStyle(controller.loop == nil ? Color.secondary : Color.accentColor)
                .frame(width: 44, height: 44)   // タッチ領域
                .contentShape(Rectangle())
        }
        // NOTE: 画面下端のボタンからメニューが上に開くと iOS は項目を逆順（先頭がボタン側）に並べる。
        //       スイング全体 → 各区間 → ループしない の宣言順で見せたいので固定する
        .menuOrder(.fixed)
        .accessibilityLabel("ループ範囲")
    }
}
