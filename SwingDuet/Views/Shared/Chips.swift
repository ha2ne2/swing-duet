import SwiftUI

// 映像や操作パネルに重ねる小さな表示の見た目。同じ組み立てが画面ごとに散らないようにここへ集める

/// 映像に重ねる黒幕の濃さ
enum Scrim {
    /// 小さな表示（チップ）の地と、解析中の幕
    static let light = 0.55
    /// 失敗の幕（下に文字を読ませる）
    static let medium = 0.7
    /// 全画面の幕（下の映像を隠す）
    static let heavy = 0.85
}

extension View {
    /// 動画の上に重ねる押せる表示：枠付きの半透明のカプセル
    /// - Parameter touchTarget: 押せるものは高さ 44pt でタッチ領域を確保する。押せない表示（進捗など）は文字の高さのまま
    func paneChip(touchTarget: Bool = true) -> some View {
        font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(Scrim.light), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35)))
            .foregroundStyle(.white)
            .frame(minHeight: touchTarget ? 44 : nil)
    }

    /// 映像の上に重ねる読むだけの表示（枠なしの半透明カプセル）。fps・長さ・倍率などの添え物に使う
    func videoChip(font: Font = .caption.bold()) -> some View {
        self.font(font)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(Scrim.light), in: Capsule())
            .foregroundStyle(.white)
    }

    /// 操作パネル・フェーズ調整の小さなカプセルボタン。選んでいる間は色を変える。
    /// 押せるので 44pt のタッチ領域を確保する（HIG。AGENTS.md §5.2）
    func capsuleChip(font: Font = .caption, selected: Bool = false,
                     selectedStyle: AnyShapeStyle = AnyShapeStyle(Color.accentColor)) -> some View {
        self.font(font)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? selectedStyle : AnyShapeStyle(.quaternary), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
