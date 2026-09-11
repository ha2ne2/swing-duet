import SwiftUI

/// ペイン右上の「替える」。押すとその側の動画を選び直す。名前は画面に出さず（映像を隠さない）、VoiceOver の値にだけ持つ
struct PaneSwapButton: View {
    let side: VideoSide
    /// クリップの表示名と倍率（VoiceOver と UI テストが読む）
    let title: String
    let onSwap: () -> Void

    var body: some View {
        Button(action: onSwap) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("替える")
            }
            .paneChip()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("動画を替える")
        .accessibilityValue(title)
        .accessibilityIdentifier("pane.\(side.rawValue).swap")
        .padding(.horizontal, 6)
    }
}

extension View {
    /// 動画の上に重ねるボタンの見た目：枠付きの半透明のカプセル。高さ 44pt でタッチ領域を確保する
    func paneChip() -> some View {
        font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35)))
            .foregroundStyle(.white)
            .frame(minHeight: 44)
    }
}
