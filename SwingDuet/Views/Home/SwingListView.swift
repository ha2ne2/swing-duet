import SwiftUI

/// 起動画面：自分のスイングの一覧（★ ベストの節と、撮影日ごとの節）。行をタップするとステージ（`StageView`）。
/// 下端の「＋ スイングを追加」で写真ライブラリから 1 本選ぶ。「選択」でまとめて ★ / 削除。削除は即時で、下端の「元に戻す」で戻せる
struct SwingListView: View {
    @EnvironmentObject private var store: ClipStore

    @State private var path: [UUID] = []
    @State private var showingPicker = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var renaming: Clip?
    @State private var errorMessage: String?

    private var isEditing: Bool { editMode.isEditing }

    /// 撮影日ごとの節（★ ベストは別の節に出すので除く）。新しい日から
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
                        Text("下の＋から、撮ったスイングを追加します。")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("スイング")
            .navigationDestination(for: UUID.self) { id in
                StageView(swingID: id)
            }
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("すべて選択") { selection = Set(store.swings.map(\.id)) }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { endEditing() }
                            .bold()
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("選択") { editMode = .active }
                            .disabled(store.swings.isEmpty)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .sheet(isPresented: $showingPicker) {
                VideoPickerSheet(destination: .mine, initialTab: .library) { picked in
                    open(picked)
                }
                .environmentObject(store)
            }
            .renameAlert($renaming)
            .errorAlert($errorMessage)
        }
    }

    private var list: some View {
        // NOTE: 複数選択の binding を常に渡すと、iPhone では行のタップが選択に取られて NavigationLink が押せなくなる。選択モードのときだけ渡す
        List(selection: isEditing ? $selection : nil) {
            if !store.bests.isEmpty {
                Section("★ ベスト") {
                    ForEach(store.bests) { clip in
                        row(clip, showsDate: true)
                    }
                }
            }
            let sections = days
            ForEach(sections, id: \.day) { group in
                Section {
                    ForEach(group.items) { clip in
                        row(clip, showsDate: false)
                    }
                } header: {
                    Text(group.day.dayLabel)
                } footer: {
                    if group.day == sections.last?.day {
                        Text("★ 以外は \(ClipStore.swingLimit) 本まで残ります")
                    }
                }
            }
        }
    }

    private func row(_ clip: Clip, showsDate: Bool) -> some View {
        NavigationLink(value: clip.id) {
            SwingRow(clip: clip, showsDate: showsDate, isEditing: isEditing) {
                renaming = clip
            }
        }
        .accessibilityIdentifier("swing.\(clip.id.uuidString)")
    }

    /// 下端：通常は「＋ スイングを追加」、選択中はまとめて ★ / 削除。削除の直後は「元に戻す」
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !store.lastDeleted.isEmpty {
                UndoBanner()
            }
            if isEditing {
                selectionBar
            } else {
                Button {
                    showingPicker = true
                } label: {
                    Label("スイングを追加", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .frame(height: 46)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("list.addSwing")
            }
        }
        .padding(.vertical, 10)
    }

    private var selectionBar: some View {
        let selected = store.swings.filter { selection.contains($0.id) }
        let allFavorite = !selected.isEmpty && selected.allSatisfy(\.isFavorite)
        return HStack {
            Button(allFavorite ? "★ ベストから外す" : "★ ベストに入れる") {
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

    private func endEditing() {
        selection = []
        editMode = .inactive
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

/// 一覧の行：自分と相手のインパクトのサムネイル、名前（無ければ時刻）、テンポ比と最後に比べたお手本、☆、「…」
private struct SwingRow: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip
    /// ★ ベストの節では日付も出す（日付の節では時刻だけ）
    let showsDate: Bool
    let isEditing: Bool
    let onRename: () -> Void

    private var title: String {
        if !clip.name.isEmpty { return clip.name }
        return showsDate ? clip.sortDate.compactLabel : clip.sortDate.timeLabel
    }

    private var partner: Clip? { store.partner(of: clip) }

    var body: some View {
        HStack(spacing: 12) {
            // 左が自分、右が相手（無ければ空の枠）。どちらもインパクトのコマ
            HStack(spacing: 2) {
                thumbnail(of: clip)
                    .opacity(clip.isAnalyzed ? 1 : 0.4)
                if let partner {
                    thumbnail(of: partner)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: 44, height: 60)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(clip.isAnalyzed ? .primary : .secondary)
                subtitle
                    .font(.caption)
            }
            Spacer(minLength: 4)
            if !isEditing {
                Button {
                    store.setFavorite(clip.id, !clip.isFavorite)
                } label: {
                    Image(systemName: clip.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(clip.isFavorite ? .yellow : .secondary)
                        .frame(width: 44, height: 44)
                }
                .disabled(!clip.isAnalyzed)
                .accessibilityLabel("★ ベスト")
                .accessibilityValue(clip.isFavorite ? "オン" : "オフ")
                Menu {
                    if case .failed = clip.analysis {
                        Button("もう一度解析", systemImage: "arrow.clockwise") { store.retryAnalysis(clip.id) }
                    } else {
                        Button(clip.isFavorite ? "★ ベストから外す" : "★ ベストに入れる", systemImage: "star") {
                            store.setFavorite(clip.id, !clip.isFavorite)
                        }
                        Button("名前を付ける", systemImage: "pencil", action: onRename)
                    }
                    Button("削除", systemImage: "trash", role: .destructive) { store.delete([clip.id]) }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("\(title) のメニュー")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    private func thumbnail(of clip: Clip) -> some View {
        VideoThumbnail(url: store.videoURL(of: clip), time: clip.thumbnailTime(of: .impact), aspect: 44 / 60)
            .frame(width: 44, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var subtitle: some View {
        switch clip.analysis {
        case .done:
            Text("\(clip.video.phases.tempoText) · vs \(partner?.displayName ?? "お手本なし")")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .pending:
            HStack(spacing: 6) {
                if store.analyzingID == clip.id {
                    ProgressView()
                        .controlSize(.mini)
                    Text("解析中…")
                } else {
                    Text("待機中")
                }
            }
            .foregroundStyle(.secondary)
        case .failed:
            Label("解析できませんでした", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// 「N 本を削除しました　元に戻す」。出てから 6 秒で消える（その間に別の削除があれば数え直す）
private struct UndoBanner: View {
    @EnvironmentObject private var store: ClipStore

    var body: some View {
        HStack {
            Text("\(store.lastDeleted.count) 本を削除しました")
                .font(.subheadline)
            Spacer()
            Button("元に戻す") { store.restoreDeleted() }
                .bold()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .task(id: store.lastDeleted.map(\.id)) {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { store.clearDeleted() }
        }
    }
}
