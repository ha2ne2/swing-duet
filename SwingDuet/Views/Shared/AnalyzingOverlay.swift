import SwiftUI

/// 解析が終わっていないクリップに重ねる幕（解析待ち・解析中）。ステージのペインとお手本のカードで使う。
/// 失敗の見せ方は画面ごとに違う（ペインは理由と次の手、カードは印だけ）のでここには含めない
struct AnalyzingOverlay: View {
    /// 解析キューがいまこのクリップを解析しているか（`ClipStore.analyzingID`）
    let isRunning: Bool
    var controlSize: ControlSize = .regular
    var font: Font = .caption.bold()

    var body: some View {
        ZStack {
            Color.black.opacity(Scrim.light)
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(controlSize)
                    .tint(.white)
                Text(isRunning ? "解析中…" : "解析待ち")
                    .font(font)
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
    }
}
