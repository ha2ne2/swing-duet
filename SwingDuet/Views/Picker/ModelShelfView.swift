import SwiftUI

/// 「動画を選ぶ」の「お手本」タブ：登録済みのお手本と ★ お気に入り（★ の付いたスイング）のカード。
/// タップでそのまま使う（再解析なし）。カードの「…」で名前の変更・削除（お手本）、★ から外す（お気に入り）。新しいお手本は「動画」タブから
struct ModelShelfView: View {
    @EnvironmentObject private var store: ClipStore
    /// 選んだクリップを入れる側
    let destination: VideoSide
    /// 右ペインにいま入っているクリップ（「いま右に」と示す）
    let currentPartnerID: UUID?
    let onPick: (Clip) -> Void

    @State private var renaming: Clip?
    @State private var deleting: Clip?

    private static let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let sections = self.sections
                if sections.isEmpty {
                    Text(destination == .model
                         ? "お手本はまだありません。「動画」タブから選ぶと、名前を付けてここに並びます。スイングに ★ を付けても並びます。"
                         : "★ お気に入りはまだありません。スイングに ★ を付けると、ここから選べます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                ForEach(sections, id: \.0) { title, clips in
                    Text(title)
                        .font(.headline)
                    grid(clips)
                }
            }
            .padding(20)
        }
        .renameAlert($renaming)
        .confirmationDialog(
            "「\(deleting?.displayName ?? "")」を削除",
            isPresented: $deleting.isPresent(),
            titleVisibility: .visible,
            presenting: deleting
        ) { clip in
            Button("削除", role: .destructive) { store.delete([clip.id]) }
        } message: { _ in
            Text("このお手本と比べたスイングは、次に開くときにいつものお手本と比べます。")
        }
    }

    /// 出す節。左（自分）に入れるときは ★ お気に入り（中身はスイング）だけ、右（お手本）なら登録済みのお手本も出す。
    /// 置ける条件は `Clip.isMine` / `Clip.canBePartner` の 1 か所に置いてある
    private var sections: [(String, [Clip])] {
        let candidates = destination == .mine
            ? [("★ お気に入り", store.favorites)]   // ★ の中身はスイングなので左にも置ける
            : [("登録済み", store.models), ("★ お気に入り", store.favorites)]
        return candidates.filter { !$0.1.isEmpty }
    }

    private func grid(_ clips: [Clip]) -> some View {
        LazyVGrid(columns: Self.columns, spacing: 16) {
            ForEach(clips) { clip in
                ClipCard(clip: clip, badge: clip.id == currentPartnerID ? "いま右に" : nil) {
                    onPick(clip)
                } menu: {
                    if case .failed = clip.analysis {
                        Button("解析をやり直す", systemImage: "arrow.clockwise") { store.retryAnalysis(clip.id) }
                    }
                    if clip.role == .model {
                        Button("名前を変更", systemImage: "pencil") { renaming = clip }
                        Button("削除", systemImage: "trash", role: .destructive) { deleting = clip }
                    } else {
                        Button("★ お気に入りから外す", systemImage: "star.slash") { store.setFavorite(clip.id, false) }
                    }
                }
            }
        }
    }
}

/// クリップのカード（サムネイル・名前）。右上の「…」にメニュー。解析が済んでいなければ押せない
private struct ClipCard<MenuContent: View>: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip
    let badge: String?
    let onTap: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    /// 解析が終わっていないカードに重ねる印。失敗をそのまま出さないと「解析中…」のまま押せなくなる
    /// （カードの「…」から再解析できる）
    @ViewBuilder
    private var status: some View {
        switch clip.analysis {
        case .done:
            EmptyView()
        case .pending:
            AnalyzingOverlay(isRunning: store.analyzingID == clip.id, font: .caption2.bold())
        case .failed:
            ZStack {
                Color.black.opacity(Scrim.medium)
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("解析できませんでした")
                        .font(.caption2.bold())
                        .multilineTextAlignment(.center)
                    Text("このカードの「…」からやり直せます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
                .foregroundStyle(.white)
            }
            .accessibilityElement(children: .combine)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ClipThumbnail(clip: clip, phase: .address, aspect: 1, maxSize: 400)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor, in: Capsule())
                                .padding(8)
                        }
                    }
                    .overlay {
                        status
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                Text(clip.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                    .frame(minHeight: 36, alignment: .top)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!clip.isAnalyzed)
        .accessibilityLabel(clip.displayName)
        .overlay(alignment: .topTrailing) {
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("\(clip.displayName) のメニュー")
        }
    }
}
