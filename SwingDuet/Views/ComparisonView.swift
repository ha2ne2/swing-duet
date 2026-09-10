import SwiftUI

/// 比較画面：2本の動画を共通タイムラインで同時再生する。
///
/// PlaybackController は表示時に 1 度だけ作り、本体（ComparisonContent）に渡す。
/// NOTE: `@State` の初期値は View が作り直されるたびに評価されるので、init で作ると親（StageView）の再描画（履歴の保存時）ごとに
///       AVPlayer 2 つを持つ使い捨ての PlaybackController ができる。`State` のドキュメントが勧めるとおり `task` で遅延生成する
struct ComparisonView: View {
    @EnvironmentObject private var store: ProjectStore
    let project: ComparisonProject
    /// ペインのラベルをタップしたとき（その側の動画を選び直す）
    let onSelectVideo: (VideoSide) -> Void

    @State private var controller: PlaybackController?

    var body: some View {
        Group {
            if let controller {
                ComparisonContent(project: project, controller: controller, onSelectVideo: onSelectVideo)
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
    @EnvironmentObject private var store: ProjectStore
    @State private var project: ComparisonProject
    private let controller: PlaybackController
    private let onSelectVideo: (VideoSide) -> Void

    @State private var editingSide: VideoSide?

    init(project: ComparisonProject, controller: PlaybackController, onSelectVideo: @escaping (VideoSide) -> Void) {
        _project = State(initialValue: project)
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
                    player: controller.player(for: .mine),
                    config: $project.mine,
                    side: .mine,
                    onTapTitle: { onSelectVideo(.mine) },
                    onEditPhases: { editPhases(.mine) })
                VideoPaneView(
                    player: controller.player(for: .model),
                    config: $project.model,
                    side: .model,
                    title: linkedModel?.name,
                    onTapTitle: { onSelectVideo(.model) },
                    onEditPhases: { editPhases(.model) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            ControlPanelView(controller: controller, reference: $project.reference)
        }
        .onChange(of: project) { _, newValue in
            store.update(newValue)
            controller.updateSync(SyncEngine(project: newValue))
        }
        .onDisappear {
            controller.pause()
        }
        .sheet(item: $editingSide) { side in
            PhaseEditView(
                config: side == .mine ? $project.mine : $project.model,
                videoURL: store.videoURL(for: project.config(for: side).fileName),
                side: side)
        }
    }

    private func editPhases(_ side: VideoSide) {
        controller.pause()
        editingSide = side
    }
}
