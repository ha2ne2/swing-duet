import SwiftUI
import PhotosUI

/// ペインの状態
enum Slot {
    case empty
    /// 取り込み済みのファイルを解析中（title は右ペインに付けた名前）
    case analyzing(fileName: String, title: String?)
    /// 動画の設定と、紐付く登録済みお手本（右ペインに登録済みお手本を入れたとき）
    case ready(VideoConfig, modelID: UUID? = nil)
}

/// ピッカーで選ばれた動画
enum PickedVideo {
    case registered(ModelVideo)
    /// ライブラリの動画（右ペインでは名前を付けて登録する。左ペインでは name は nil）
    case library(URL, name: String?)
}

/// アプリの唯一の画面。起動時は 2 つのペインが空で、それぞれの + から動画を選ぶ。
/// 両方そろうと比較（`ComparisonView`）になり、履歴に自動で残る。
/// ツールバーは「履歴」と「新しいスイング」（ライブラリを直接開いて左ペインに入れる。一番多い操作なのでツールバーに置く）
struct StageView: View {
    @EnvironmentObject private var store: ProjectStore

    @State private var mine: Slot = .empty
    @State private var model: Slot = .empty
    /// いま開いている比較。両ペインがそろって作ったか、履歴から開いたもの
    @State private var projectID: UUID?
    @State private var picking: ReferenceSide?
    @State private var showingHistory = false
    @State private var errorMessage: String?
    /// ツールバーの「新しいスイング」で選んだライブラリの項目と、その取り出し中フラグ
    @State private var newSwingItem: PhotosPickerItem?
    @State private var importingNewSwing = false

    private var project: ComparisonProject? {
        store.projects.first { $0.id == projectID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let project {
                    ComparisonView(project: project, store: store) { side in
                        picking = side
                    }
                    .id(project.id)
                } else {
                    SetupStageView(mine: mine, model: model, store: store) { side in
                        picking = side
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingHistory = true
                    } label: {
                        // NOTE: ツールバーの Label はアイコンだけになるので、文字を出すために HStack で組む
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("履歴")
                        }
                    }
                    .accessibilityLabel("履歴")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $newSwingItem, matching: .videos) {
                        HStack(spacing: 5) {
                            if importingNewSwing {
                                ProgressView()
                            } else {
                                Image(systemName: "plus")
                            }
                            Text("新しいスイング")
                        }
                    }
                    .disabled(importingNewSwing)
                    .accessibilityLabel("新しいスイング")
                    .accessibilityIdentifier("toolbar.newSwing")
                }
            }
            .onChange(of: newSwingItem) { _, item in
                if let item { importNewSwing(item) }
            }
            .sheet(item: $picking) { side in
                VideoPickerSheet(side: side) { picked in
                    load(picked, into: side)
                }
                .environmentObject(store)
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView { project in
                    open(project)
                }
                .environmentObject(store)
            }
            .alert("動画を使えませんでした", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: project == nil) { _, isGone in
                // 開いている比較が履歴から消されたら空に戻す
                if isGone, projectID != nil { reset() }
            }
        }
    }

    // MARK: - ペインの更新

    private func slot(_ side: ReferenceSide) -> Slot {
        side == .mine ? mine : model
    }

    private func set(_ side: ReferenceSide, _ slot: Slot) {
        if side == .mine { mine = slot } else { model = slot }
    }

    private func reset() {
        projectID = nil
        mine = .empty
        model = .empty
    }

    private func open(_ project: ComparisonProject) {
        fill(from: project)
        projectID = project.id
    }

    /// 比較の動画をペインに入れる（片方だけ選び直したとき、もう片方をそのまま引き継ぐため）
    private func fill(from project: ComparisonProject) {
        mine = .ready(project.mine)
        model = .ready(project.model, modelID: project.modelID)
    }

    /// ツールバーの「新しいスイング」：選んだ動画を左ペイン（自分）に入れる。お手本はそのまま
    private func importNewSwing(_ item: PhotosPickerItem) {
        importingNewSwing = true
        Task { @MainActor in
            defer {
                importingNewSwing = false
                newSwingItem = nil   // 同じ動画をもう一度選んでも onChange が走るように
            }
            do {
                let url = try await item.loadMovieURL()
                load(.library(url, name: nil), into: .mine)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func load(_ picked: PickedVideo, into side: ReferenceSide) {
        // 開いている比較の動画は、フェーズ修正や位置合わせを反映した最新の状態で引き継ぐ
        if let project { fill(from: project) }
        projectID = nil
        switch picked {
        case .registered(let model):
            set(side, .ready(model.config, modelID: model.id))
            createProjectIfReady()
        case .library(let url, let name):
            do {
                let fileName = try store.importVideo(from: url)
                set(side, .analyzing(fileName: fileName, title: name))
                Task { await analyze(fileName: fileName, name: name, side: side) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func analyze(fileName: String, name: String?, side: ReferenceSide) async {
        do {
            // 解析より先に音声を落とす（解析が保存する duration を、以後ずっと読む書き換え後のファイルから取るため）
            await store.stripAudio(fileName)
            let result = try await SwingAnalyzer.analyze(url: store.videoURL(for: fileName))
            // 解析中に選び直されていたら、その結果は捨てる
            guard case .analyzing(let current, _) = slot(side), current == fileName else {
                store.removeVideo(fileName)
                return
            }
            let config = result.videoConfig(fileName: fileName)
            if side == .model, let name {
                let model = store.addModel(name: name, config: config)
                set(side, .ready(model.config, modelID: model.id))
            } else {
                set(side, .ready(config))
            }
            createProjectIfReady()
        } catch {
            store.removeVideo(fileName)
            set(side, .empty)
            errorMessage = "解析に失敗しました：\(error.localizedDescription)"
        }
    }

    /// 両ペインがそろったら比較を作って履歴に入れる
    private func createProjectIfReady() {
        guard case .ready(let mineConfig, _) = mine, case .ready(let modelConfig, let modelID) = model else { return }
        let project = ComparisonProject(
            name: "比較 \(Date().compactLabel)", mine: mineConfig, model: modelConfig, modelID: modelID)
        store.add(project)
        open(project)
    }
}

/// 両ペインがそろう前のステージ。ペインは空（+）・解析中・準備済みのどれかで、操作パネルは薄く表示する
private struct SetupStageView: View {
    let mine: Slot
    let model: Slot
    let store: ProjectStore
    let onSelect: (ReferenceSide) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                SlotPane(side: .mine, slot: mine, store: store) { onSelect(.mine) }
                SlotPane(side: .model, slot: model, store: store) { onSelect(.model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            placeholderControls
                .opacity(0.35)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 比較画面の操作パネルと同じ形の飾り（高さをそろえて、そろった瞬間にペインが動かないようにする）
    private var placeholderControls: some View {
        VStack(spacing: 8) {
            ReferencePicker(reference: .constant(.model))
                .padding(.horizontal)

            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(height: 28)
                SegmentLegend()
            }
            .padding(.horizontal)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([SwingPhase.address, .top, .impact]) { phase in
                        Text(phase.label)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                }
                HStack(spacing: 22) {
                    Image(systemName: "repeat").font(.title3)
                    Image(systemName: "backward.frame.fill").font(.title3)
                    Image(systemName: "play.circle.fill").font(.system(size: 44))
                    Image(systemName: "forward.frame.fill").font(.title3)
                    Text("x0.30")
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, height: 30)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }
}

/// 1 つのペイン（空・解析中・準備済み）
private struct SlotPane: View {
    let side: ReferenceSide
    let slot: Slot
    let store: ProjectStore
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Color.black
            switch slot {
            case .empty:
                Button(action: onTap) {
                    VStack(spacing: 12) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 64, weight: .light))
                        Text("動画を選ぶ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(side == .mine ? "自分の動画を選ぶ" : "お手本の動画を選ぶ")
                .accessibilityIdentifier("slot.\(side.rawValue).add")
            case .analyzing(let fileName, _):
                VideoThumbnail(url: store.videoURL(for: fileName), time: 0, maxSize: 800)
                    .overlay(Color.black.opacity(0.55))
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("解析中…")
                        .font(.caption.bold())
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("slot.\(side.rawValue).analyzing")
            case .ready(let config, _):
                VideoThumbnail(url: store.videoURL(for: config.fileName), time: config.phases.address, maxSize: 800)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 左右のペインは常に同じ幅
        .overlay(alignment: .topLeading) {
            // 比較画面（VideoPaneView）のラベルと同じ位置・見た目にして、そろった瞬間にラベルが動かないようにする
            Text(side.paneTitle(modelName))
                .lineLimit(1)
                .paneChip()
                .padding(.horizontal, 6)
        }
    }

    /// ラベルに添える登録済みお手本の名前（右ペインで名前を付けた直後は解析中でも出す）
    private var modelName: String? {
        switch slot {
        case .empty: return nil
        case .analyzing(_, let title): return title
        case .ready(_, let modelID): return store.model(id: modelID)?.name
        }
    }
}
