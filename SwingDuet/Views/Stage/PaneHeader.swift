import SwiftUI

/// ペイン上端：左に名前（読むだけ）、右に「替える」（押すとその側の動画を選び直す）。
/// ラベルと操作を分けて、押せるものが枠付きの「替える」だけに見えるようにする。「自分」「お手本」は左右の並びが固定なので書かない
struct PaneHeader: View {
    let side: VideoSide
    /// 名前（クリップの表示名と倍率）
    let title: String
    let onSwap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
                .paneChip()
            Spacer(minLength: 0)
            Button(action: onSwap) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("替える")
                }
                .paneChip(bordered: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("動画を替える")
            .accessibilityValue(title)
            .accessibilityIdentifier("pane.\(side.rawValue).swap")
        }
        .padding(.horizontal, 6)
    }
}

extension View {
    /// 動画の上に重ねる半透明のカプセル。高さ 44pt でタッチ領域を確保し、ボタンには枠を付けてラベルと見分ける
    func paneChip(bordered: Bool = false) -> some View {
        font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(bordered ? 0.35 : 0)))
            .foregroundStyle(.white)
            .frame(minHeight: 44)
    }
}
