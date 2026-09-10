import SwiftUI

/// 比較画面：左（スイング）と右（お手本）の 2 本を共通タイムラインで同時再生する。
///
/// PlaybackController は表示時に 1 度だけ作り、本体（ComparisonContent）に渡す。
/// NOTE: `@State` の初期値は View が作り直されるたびに評価されるので、init で作ると親（StageView）の再描画（保存時）ごとに
///       AVPlayer 2 つを持つ使い捨ての PlaybackController ができる。`State` のドキュメントが勧めるとおり `task` で遅延生成する
struct ComparisonView: View {
    @EnvironmentObject private var store: ClipStore
    let left: Clip
    let right: Clip
    /// ペインのラベルをタップしたとき（その側の動画を選び直す）
    let onSelectVideo: (VideoSide) -> Void

    @State private var controller: PlaybackController?

    var body: some View {
        Group {
            if let controller {
                ComparisonContent(left: left, right: right, controller: controller, onSelectVideo: onSelectVideo)
            } else {
                Color.black.task {
                    controller = PlaybackController(
                        mineURL: store.videoURL(for: left.fileName),
                        modelURL: store.videoURL(for: right.fileName),
                        sync: SyncEngine(mine: left.video, model: left.pairedConfig(of: right), reference: store.reference))
                }
            }
        }
    }
}

/// 比較画面の本体。左右の編集（フェーズ・表示変換）と基準を保存し、同期設定の変更を controller に反映する。
/// 左の編集はスイングに、右のフェーズはお手本そのもの（そのお手本を使うすべてのスイングに効く）に、右の位置合わせはスイングの `pairing` に書く
private struct ComparisonContent: View {
    @EnvironmentObject private var store: ClipStore
    private let left: Clip
    private let right: Clip
    private let controller: PlaybackController
    private let onSelectVideo: (VideoSide) -> Void

    @State private var mine: VideoConfig
    @State private var model: VideoConfig
    @State private var editingSide: VideoSide?

    init(left: Clip, right: Clip, controller: PlaybackController, onSelectVideo: @escaping (VideoSide) -> Void) {
        self.left = left
        self.right = right
        self.controller = controller
        self.onSelectVideo = onSelectVideo
        _mine = State(initialValue: left.video)
        _model = State(initialValue: left.pairedConfig(of: right))
    }

    private var reference: Binding<VideoSide> {
        Binding(get: { store.reference }, set: { store.reference = $0 })
    }

    var body: some View {
        VStack(spacing: 8) {
            // 動画ペイン（左右並び）
            HStack(spacing: 2) {
                VideoPaneView(
                    player: controller.player(for: .mine),
                    config: $mine,
                    side: .mine,
                    title: left.displayName,
                    onTapTitle: { onSelectVideo(.mine) },
                    onEditPhases: { editPhases(.mine) })
                VideoPaneView(
                    player: controller.player(for: .model),
                    config: $model,
                    side: .model,
                    title: right.displayName,
                    onTapTitle: { onSelectVideo(.model) },
                    onEditPhases: { editPhases(.model) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            ControlPanelView(controller: controller, reference: reference)
        }
        .onChange(of: mine) { _, newValue in
            var clip = left
            clip.video = newValue
            store.update(clip)
            updateSync()
        }
        .onChange(of: model) { _, newValue in
            var partner = right
            partner.video.phases = newValue.phases
            partner.video.candidates = newValue.candidates
            partner.video.lowConfidence = newValue.lowConfidence
            store.update(partner)
            var clip = left
            clip.pairing = Pairing(partnerID: right.id, transformOf: newValue, pairedAt: left.pairing?.pairedAt ?? Date())
            store.update(clip)
            updateSync()
        }
        .onChange(of: store.reference) { _, _ in
            updateSync()
        }
        .task {
            await controller.playWhenReady()   // 開いたら自動で再生
        }
        .onDisappear {
            controller.pause()
        }
        .sheet(item: $editingSide) { side in
            PhaseEditView(
                config: side == .mine ? $mine : $model,
                videoURL: store.videoURL(for: side == .mine ? left.fileName : right.fileName),
                side: side)
        }
    }

    private func updateSync() {
        controller.updateSync(SyncEngine(mine: mine, model: model, reference: store.reference))
    }

    private func editPhases(_ side: VideoSide) {
        controller.pause()
        editingSide = side
    }
}
