import SwiftUI

/// 起動画面：自分のスイングの一覧（★ お気に入りの節と、撮影日ごとの節）。行をタップするとステージ（`StageView`）。
/// 下端の「撮影」で撮影画面（`CaptureView`。打つだけで 1 球ずつ残る）、「ライブラリから」で写真ライブラリから 1 本選ぶ（同じ見た目のカプセル 2 つ）。
/// 「選択」でまとめて ★ / 削除。削除は即時で、下端の「元に戻す」で戻せる
struct SwingListView: View {
    @EnvironmentObject private var store: ClipStore

    @State private var path: [UUID] = []
    @State private var showingPicker = false
    @State private var showingCapture = false
    /// 撮影を止めた結果（下端の帯に数秒出す）
    @State private var captureSummary: CaptureController.Summary?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var renaming: Clip?
    @State private var errorMessage: String?

    private var isEditing: Bool { editMode.isEditing }

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

    private var list: some View {
        // NOTE: 複数選択の binding を常に渡すと、iPhone では行のタップが選択に取られて NavigationLink が押せなくなる。選択モードのときだけ渡す
        List(selection: isEditing ? $selection : nil) {
            if !store.favorites.isEmpty {
                Section("★ お気に入り") {
                    ForEach(store.favorites) { clip in
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
                        Text("★ 以外は \(ClipStore.swingLimit) 本まで残ります（今日の分は数えません）")
                    }
                }
            }
        }
    }

    private func row(_ clip: Clip, showsDate: Bool) -> some View {
        SwingRow(clip: clip, showsDate: showsDate, isEditing: isEditing) {
            renaming = clip
        }
        // NOTE: NavigationLink を行の中身にすると右端に > が付く。透明な NavigationLink を背景に敷けば、行全体のタップで遷移しつつ > は出ない
        .background(NavigationLink(value: clip.id) { EmptyView() }.opacity(0))
        .accessibilityIdentifier("swing.\(clip.id.uuidString)")
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
            if isEditing {
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
    /// ★ お気に入りの節では日付も出す（日付の節では時刻だけ）
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
                FavoriteButton(clip: clip, dimsWhenOff: true)
                    .frame(width: 44, height: 44)
                Menu {
                    if case .failed = clip.analysis {
                        Button("もう一度解析", systemImage: "arrow.clockwise") { store.retryAnalysis(clip.id) }
                    } else {
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
        ClipThumbnail(clip: clip, phase: .impact, aspect: 44 / 60)
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
                    Text("解析待ち")
                }
            }
            .foregroundStyle(.secondary)
        case .failed:
            Label("解析できませんでした", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}
