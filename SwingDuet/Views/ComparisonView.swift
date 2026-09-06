import SwiftUI

/// 比較画面：2本の動画を共通タイムラインで同時再生する。
///
/// PlaybackController は表示時に 1 度だけ作り、本体（ComparisonContent）に渡す。
/// NOTE: `@State` の初期値は View が作り直されるたびに評価されるので、init で作ると親（StageView）の再描画（履歴の保存時）ごとに
///       AVPlayer 2 つを持つ使い捨ての PlaybackController ができる。`State` のドキュメントが勧めるとおり `task` で遅延生成する
struct ComparisonView: View {
    let project: ComparisonProject
    let store: ProjectStore
    /// ペインのラベルをタップしたとき（その側の動画を選び直す）
    let onSelectVideo: (ReferenceSide) -> Void

    @State private var controller: PlaybackController?

    var body: some View {
        Group {
            if let controller {
                ComparisonContent(project: project, store: store, controller: controller, onSelectVideo: onSelectVideo)
            } else {
                Color.black.task {
                    controller = PlaybackController(
                        mineURL: store.videoURL(for: project.mine.fileName),
                        modelURL: store.videoURL(for: project.model.fileName),
                        sync: SyncEngine(project: project))
                }
            }
        }
    }
}

/// 比較画面の本体。project の編集（基準・フェーズ・表示変換）を保存し、同期設定の変更を controller に反映する
private struct ComparisonContent: View {
    @State private var project: ComparisonProject
    @ObservedObject private var store: ProjectStore
    private let controller: PlaybackController
    private let onSelectVideo: (ReferenceSide) -> Void

    @State private var editingSide: ReferenceSide?

    init(project: ComparisonProject, store: ProjectStore, controller: PlaybackController, onSelectVideo: @escaping (ReferenceSide) -> Void) {
        _project = State(initialValue: project)
        self.store = store
        self.controller = controller
        self.onSelectVideo = onSelectVideo
    }

    /// 紐付いている登録済みお手本（登録を消していれば nil）
    private var linkedModel: ModelVideo? { store.model(id: project.modelID) }

    var body: some View {
        VStack(spacing: 8) {
            // 動画ペイン（左右並び）
            HStack(spacing: 2) {
                VideoPaneView(
                    player: controller.minePlayer,
                    config: $project.mine,
                    side: .mine,
                    onTapTitle: { onSelectVideo(.mine) })
                VideoPaneView(
                    player: controller.modelPlayer,
                    config: $project.model,
                    side: .model,
                    title: linkedModel?.name,
                    onTapTitle: { onSelectVideo(.model) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            if project.mine.lowConfidence || project.model.lowConfidence {
                Text("フェーズの自動検出の信頼度が低い動画があります。「フェーズ調整」で確認してください。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            } else if project.mine.candidates.count > 1 || project.model.candidates.count > 1 {
                Text("複数のスイングを検出し、振り切ったものを選びました。「フェーズ調整」で他の候補に切り替えられます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            // テンポ比 + フェーズ調整 + 基準切り替え
            HStack(spacing: 10) {
                tempoBadge(side: .mine)
                tempoBadge(side: .model)
                Spacer()
                Picker("基準", selection: $project.reference) {
                    ForEach(ReferenceSide.allCases) { side in
                        Text("\(side.label)基準").tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            .padding(.horizontal)

            SeekBarView(controller: controller)
                .padding(.horizontal)

            TransportControlsView(controller: controller)
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
        .onChange(of: project) { _, newValue in
            store.update(newValue)
            controller.updateSync(SyncEngine(project: newValue))
        }
        .onDisappear {
            controller.shutdown()
        }
        .sheet(item: $editingSide) { side in
            PhaseEditView(
                config: side == .mine ? $project.mine : $project.model,
                videoURL: store.videoURL(for: project.config(for: side).fileName),
                side: side)
        }
    }

    private func tempoBadge(side: ReferenceSide) -> some View {
        Button {
            controller.pause()
            editingSide = side
        } label: {
            HStack(spacing: 4) {
                Text("\(side.label) \(project.config(for: side).phases.tempoText)")
                    .font(.caption.monospacedDigit())
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
