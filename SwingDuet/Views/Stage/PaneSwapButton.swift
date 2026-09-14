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
