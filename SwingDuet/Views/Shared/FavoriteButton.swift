import SwiftUI

/// ★ お気に入りの切り替え（一覧の行とステージのツールバー）。解析が済むまでは押せない
struct FavoriteButton: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip
    /// 一覧では付いていないとき灰色にする（並んだ行の中で目立たせない）。ツールバーでは常に黄色
    var dimsWhenOff = false
    /// UI テストが押すための識別子。ラベル・値と同じ要素（ボタン本体）に付ける
    var identifier = ""


    var body: some View {
        Button {
            store.setFavorite(clip.id, !clip.isFavorite)
        } label: {
            Image(systemName: clip.isFavorite ? "star.fill" : "star")
                .foregroundStyle(dimsWhenOff && !clip.isFavorite ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.yellow))
                .symbolEffect(.bounce, value: clip.isFavorite)
        }
        .disabled(!clip.isAnalyzed)
        .accessibilityLabel("★ お気に入り")
        .accessibilityValue(clip.isFavorite ? "オン" : "オフ")
        .accessibilityIdentifier(identifier)
    }
}
