import SwiftUI

/// 起動画面：自分のスイングの一覧（★ お気に入りの節と、撮影日ごとの節）。インパクトのコマを並べた格子で、
/// セルをタップするとステージ（`StageView`）。名前・削除は長押しのメニュー。
/// 下端の「撮影」で撮影画面（`CaptureView`。打つだけで 1 球ずつ残る）、「ライブラリから」で写真ライブラリから 1 本選ぶ（同じ見た目のカプセル 2 つ）。
/// 「選択」でまとめて ★ / 削除。削除は即時で、下端の「元に戻す」で戻せる
struct SwingListView: View {
    @EnvironmentObject private var store: ClipStore

    @State private var path: [UUID] = []
    @State private var showingPicker = false
    @State private var showingCapture = false
    /// 撮影を止めた結果（下端の帯に数秒出す）
    @State private var captureSummary: CaptureController.Summary?
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var renaming: Clip?
    @State private var errorMessage: String?

    /// 格子は 1 行 3 枚、縦長のスイング動画に合わせて 3 : 4
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private static let cellAspect: CGFloat = 3.0 / 4.0

    /// 撮影日ごとの節（★ お気に入りは別の節に出すので除く）。新しい日から
    private var days: [(day: Date, items: [Clip])] {
        store.swings.filter { !$0.isFavorite }.groupedByDay(\.sortDate)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.swings.isEmpty {
                    ContentUnavailableView {
                        Label("スイングはまだありません", systemImage: "figure.golf")
                    } description: {
                        Text("下の「撮影」で撮るか、「ライブラリから」追加します。")
                    }
                } else {
                    grid
                }
            }
            .navigationTitle("スイング")
            .navigationDestination(for: UUID.self) { id in
                StageView(swingID: id)
            }
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("すべて選択") { selection = Set(store.swings.map(\.id)) }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { endEditing() }
                            .bold()
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("選択") { isSelecting = true }
                            .disabled(store.swings.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .sheet(isPresented: $showingPicker) {
                VideoPickerSheet(destination: .mine, initialTab: .library) { picked in
                    open(picked)
                }
                .environmentObject(store)
            }
            .fullScreenCover(isPresented: $showingCapture) {
                CaptureView(store: store) { summary in
                    captureSummary = summary
                }
                .environmentObject(store)
            }
            .renameAlert($renaming)
            .errorAlert($errorMessage)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                // clips からの絞り込みと並べ替えなので、1 回の描画で何度も引かない
                let favorites = store.favorites
                if !favorites.isEmpty {
                    section("★ お気に入り", favorites, showsDate: true)
                }
                ForEach(days, id: \.day) { group in
                    section(group.day.dayLabel, group.items, showsDate: false)
                }
                Text("★ 以外は \(ClipStore.swingLimit) 本まで残ります（今日の分は数えません）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }
            .padding(.bottom, 20)
        }
        .accessibilityIdentifier("list.grid")
    }

    private func section(_ title: String, _ clips: [Clip], showsDate: Bool) -> some View {
        Group {
            Text(title)
                .font(.subheadline.bold())
                .padding(.horizontal, 12)
                .padding(.top, 8)
            LazyVGrid(columns: Self.columns, spacing: 2) {
                ForEach(clips) { clip in
                    SwingCell(clip: clip, showsDate: showsDate, aspect: Self.cellAspect,
                              isSelecting: isSelecting, isSelected: selection.contains(clip.id),
                              onTap: { tap(clip) }, onRename: { renaming = clip })
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// セルのタップ。選択モードでは選び、そうでなければステージを開く
    private func tap(_ clip: Clip) {
        guard isSelecting else {
            path.append(clip.id)
            return
        }
        if selection.contains(clip.id) {
            selection.remove(clip.id)
        } else {
            selection.insert(clip.id)
        }
    }

    /// 下端：通常は「撮影」「ライブラリから」（同じ見た目のカプセル 2 つ）、選択中はまとめて ★ / 削除。削除の直後は「元に戻す」、撮影の直後は結果の帯
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if store.isReadOnly {
                Text("保存データを安全に読めないため、変更は保存されません。動画は残しています。" +
                     (store.damagedLibraryBackup.map { "\n退避: \($0)" } ?? "\n退避にも失敗しました。元の保存データは変更していません。"))
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .accessibilityIdentifier("list.storageProtection")
            }
            if !store.lastDeleted.isEmpty {
                BottomBanner(text: "\(store.lastDeleted.count) 本を削除しました", actionTitle: "元に戻す",
                             dismissAfter: .seconds(6), id: store.lastDeleted.map(\.id),
                             action: { store.restoreDeleted() }, onTimeout: { store.clearDeleted() })
            }
            if let summary = captureSummary {
                BottomBanner(text: Self.summaryText(summary), actionTitle: "OK",
                             dismissAfter: .seconds(8), id: summary) {
                    captureSummary = nil
                }
                .accessibilityIdentifier("list.captureSummary")
            }
            if isSelecting {
                selectionBar
            } else {
                HStack(spacing: 10) {
                    capsuleButton("撮影", systemImage: "video.fill") { showingCapture = true }
                        .accessibilityIdentifier("list.capture")
                    capsuleButton("ライブラリから", systemImage: "plus") { showingPicker = true }
                        .accessibilityIdentifier("list.addSwing")
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func capsuleButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private var selectionBar: some View {
        let selected = store.swings.filter { selection.contains($0.id) }
        let allFavorite = !selected.isEmpty && selected.allSatisfy(\.isFavorite)
        return HStack {
            Button(allFavorite ? "★ お気に入りから外す" : "★ お気に入りに追加") {
                for clip in selected { store.setFavorite(clip.id, !allFavorite) }
                endEditing()
            }
            Spacer()
            Button("削除", role: .destructive) {
                store.delete(selection)
                endEditing()
            }
        }
        .disabled(selected.isEmpty)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    /// 撮影を止めた直後の帯の文面。自動で止めたときはその理由、1 球も切り出せなかったときは長回しを残したことを出す
    private static func summaryText(_ summary: CaptureController.Summary) -> String {
        var lines: [String] = []
        if let reason = summary.reason { lines.append(reason) }
        if summary.savedTake {
            lines.append("ショットは見つかりませんでした。撮った動画を残したので、解析で 1 球ずつに分けます")
        } else {
            lines.append("\(summary.shotCount) 球を保存しました")
            if summary.keptTake { lines.append("全体の動画も残しました") }
        }
        return lines.joined(separator: "。")
    }

    private func endEditing() {
        selection = []
        isSelecting = false
    }

    /// ピッカーで選んだ動画を開く。ライブラリの動画は取り込んでスイングにし（同じ動画のスイングがあればそれ）、ステージへ
    private func open(_ picked: PickedVideo) {
        switch picked {
        case .existing(let clip):
            path.append(clip.id)
        case .library(let source, _):
            Task {
                do {
                    let clip = try await store.obtain(role: .swing, source: source)
                    path.append(clip.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// 一覧の格子のセル：インパクトのコマ 1 枚に、題（名前か時刻）・★・解析の状態を重ねる。
/// 名前・削除・再解析は長押しのメニュー（格子には置く場所が無い）
private struct SwingCell: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip
    /// ★ お気に入りの節では日付も出す（日付の節では時刻だけ）
    let showsDate: Bool
    let aspect: CGFloat
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onRename: () -> Void

    private var title: String {
        if !clip.name.isEmpty { return clip.name }
        return showsDate ? clip.sortDate.compactLabel : clip.sortDate.timeLabel
    }

    var body: some View {
        Button(action: onTap) {
            // 1 行 3 枚のセルは iPhone で 130pt 前後。44pt の行より大きいので、既定の 256px では粗い
            ClipThumbnail(clip: clip, phase: .impact, aspect: aspect, maxSize: 512)
                .aspectRatio(aspect, contentMode: .fit)
                .opacity(clip.isAnalyzed ? 1 : 0.4)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomLeading) {
                    Text(title)
                        .font(.caption2.bold())
                        .lineLimit(1)
                        .shadow(radius: 2)
                        .padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if clip.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .shadow(radius: 2)
                            .padding(4)
                    }
                }
                .overlay(alignment: .topLeading) { analysisBadge }
                .overlay {
                    if isSelecting { selectionMark }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { if !isSelecting { menu } }
        .accessibilityIdentifier("swing.\(clip.id.uuidString)")
        .accessibilityLabel(accessibilityText)
    }

    /// 解析の状態（済んでいれば何も出さない）
    @ViewBuilder
    private var analysisBadge: some View {
        switch clip.analysis {
        case .done:
            EmptyView()
        case .pending:
            Group {
                if store.analyzingID == clip.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(4)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .shadow(radius: 2)
                .padding(4)
        }
    }

    /// 選択モードの印（選んだセルは枠も付ける）
    private var selectionMark: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.35)))
                    .padding(4)
            }
    }

    @ViewBuilder
    private var menu: some View {
        if case .failed = clip.analysis {
            Button("もう一度解析", systemImage: "arrow.clockwise") { store.retryAnalysis(clip.id) }
        } else {
            Button("名前を付ける", systemImage: "pencil", action: onRename)
            Button(clip.isFavorite ? "★ お気に入りから外す" : "★ お気に入りに追加",
                   systemImage: clip.isFavorite ? "star.slash" : "star") {
                store.setFavorite(clip.id, !clip.isFavorite)
            }
            .disabled(!clip.isAnalyzed)
        }
        Button("削除", systemImage: "trash", role: .destructive) { store.delete([clip.id]) }
    }

    /// 「9/10 14:32, ★, 解析中」。格子では文字が 1 行しか置けないので、状態は読み上げで補う
    private var accessibilityText: String {
        var parts = [title]
        if clip.isFavorite { parts.append("★ お気に入り") }
        switch clip.analysis {
        case .done: break
        case .pending: parts.append(store.analyzingID == clip.id ? "解析中" : "解析待ち")
        case .failed: parts.append("解析できませんでした")
        }
        if isSelecting { parts.append(isSelected ? "選択中" : "未選択") }
        return parts.joined(separator: ", ")
    }
}
