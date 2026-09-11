import SwiftUI

/// 「動画を選ぶ」の「お手本」タブ：登録済みのお手本と ★ ベスト（★ の付いたスイング）のカード。
/// タップでそのまま使う（再解析なし）。カードの「…」で名前の変更・削除（お手本）、★ から外す（ベスト）。新しいお手本は「動画」タブから
struct ModelShelfView: View {
    @EnvironmentObject private var store: ClipStore
    /// 右ペインにいま入っているクリップ（「いま右に」と示す）
    let currentPartnerID: UUID?
    let onPick: (Clip) -> Void

    @State private var renaming: Clip?
    @State private var deleting: Clip?

    private static let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.models.isEmpty && store.bests.isEmpty {
                    Text("お手本はまだありません。「動画」タブから選ぶと、名前を付けてここに並びます。スイングに ★ を付けても並びます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                if !store.models.isEmpty {
                    Text("登録済み")
                        .font(.headline)
                    grid(store.models)
                }
                if !store.bests.isEmpty {
                    Text("★ ベスト")
                        .font(.headline)
                    grid(store.bests)
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

    private func grid(_ clips: [Clip]) -> some View {
        LazyVGrid(columns: Self.columns, spacing: 16) {
            ForEach(clips) { clip in
                ClipCard(clip: clip, badge: clip.id == currentPartnerID ? "いま右に" : nil) {
                    onPick(clip)
                } menu: {
                    if clip.role == .model {
                        Button("名前を変更", systemImage: "pencil") { renaming = clip }
                        Button("削除", systemImage: "trash", role: .destructive) { deleting = clip }
                    } else {
                        Button("★ ベストから外す", systemImage: "star.slash") { store.setFavorite(clip.id, false) }
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

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                VideoThumbnail(url: store.videoURL(of: clip), time: clip.thumbnailTime(of: .address), aspect: 1, maxSize: 400)
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
                        if !clip.isAnalyzed {
                            ZStack {
                                Color.black.opacity(0.55)
                                VStack(spacing: 6) {
                                    ProgressView()
                                        .tint(.white)
                                    Text("解析中…")
                                        .font(.caption2.bold())
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
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
