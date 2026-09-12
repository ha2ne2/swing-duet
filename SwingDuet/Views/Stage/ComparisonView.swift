import SwiftUI
import AVFoundation

/// 比較画面：左（スイング）と右（お手本）の 2 本を共通タイムラインで同時再生する。
///
/// 動画（`ClipStore.videoAsset(of:)`。写真ライブラリの参照は iCloud からのダウンロードを含む）を解いてから PlaybackController を 1 度だけ作り、
/// 本体（ComparisonContent）に渡す。解けなければ（写真アプリで消された等）理由を出す。
/// NOTE: `@State` の初期値は View が作り直されるたびに評価されるので、init で作ると親（StageView）の再描画（保存時）ごとに
///       AVPlayer 2 つを持つ使い捨ての PlaybackController ができる。`State` のドキュメントが勧めるとおり `task` で遅延生成する
struct ComparisonView: View {
    @EnvironmentObject private var store: ClipStore
    let left: Clip
    let right: Clip
    /// ペイン右上の「替える」をタップしたとき（その側の動画を選び直す）
    let onSelectVideo: (VideoSide) -> Void

    /// 解いた動画と、それで作った controller
    @State private var loaded: (mine: AVAsset, model: AVAsset, controller: PlaybackController)?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loaded {
                ComparisonContent(left: left, right: right, mineAsset: loaded.mine, modelAsset: loaded.model,
                                  controller: loaded.controller, onSelectVideo: onSelectVideo)
            } else if let loadError {
                ContentUnavailableView("動画を読み込めません", systemImage: "video.slash",
                                       description: Text(loadError + "\n一覧の「…」から削除できます。"))
            } else {
                ZStack {
                    Color.black
                    ProgressView("動画を読み込み中…")
                        .tint(.white)
                }
                .task {
                    do {
                        let mine = try await store.videoAsset(of: left)
                        let model = try await store.videoAsset(of: right)
                        let controller = PlaybackController(
                            mineItem: try await VideoImporter.playerItem(for: mine),
                            modelItem: try await VideoImporter.playerItem(for: model),
                            mine: left.video, model: left.pairedConfig(of: right),
                            settings: store.playback)
                        loaded = (mine, model, controller)
                    } catch {
                        loadError = error.localizedDescription
                    }
                }
            }
        }
    }
}

/// 比較画面の本体。左右の編集（フェーズ・表示変換）と再生の設定を保存し、フェーズの変更を controller に反映する。
/// 左の編集はスイングに、右のフェーズと速さはお手本そのもの（そのお手本を使うすべてのスイングに効く）に、右の位置合わせはスイングの `pairing` に書く
private struct ComparisonContent: View {
    @EnvironmentObject private var store: ClipStore
    private let left: Clip
    private let right: Clip
    /// 解いた動画（フェーズ調整のプレビューに渡す）
    private let mineAsset: AVAsset
    private let modelAsset: AVAsset
    private let controller: PlaybackController
    private let onSelectVideo: (VideoSide) -> Void

    @State private var mine: VideoConfig
    @State private var model: VideoConfig
    @State private var editingSide: VideoSide?

    init(left: Clip, right: Clip, mineAsset: AVAsset, modelAsset: AVAsset, controller: PlaybackController,
         onSelectVideo: @escaping (VideoSide) -> Void) {
        self.left = left
        self.right = right
        self.mineAsset = mineAsset
        self.modelAsset = modelAsset
        self.controller = controller
        self.onSelectVideo = onSelectVideo
        _mine = State(initialValue: left.video)
        _model = State(initialValue: left.pairedConfig(of: right))
    }

    var body: some View {
        VStack(spacing: 8) {
            // 動画ペイン（左右並び）
            HStack(spacing: 2) {
                VideoPaneView(
                    player: controller.player(for: .mine),
                    config: $mine,
                    side: .mine,
                    title: left.paneTitle,
                    onSwap: { onSelectVideo(.mine) },
                    onEditPhases: { editPhases(.mine) })
                VideoPaneView(
                    player: controller.player(for: .model),
                    config: $model,
                    side: .model,
                    title: right.paneTitle,
                    onSwap: { onSelectVideo(.model) },
                    onEditPhases: { editPhases(.model) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            ControlPanelView(controller: controller)
        }
        .onChange(of: mine) { _, newValue in
            var clip = left
            clip.video = newValue
            store.update(clip)
            updateVideos()
        }
        .onChange(of: model) { _, newValue in
            // 相手には解析結果だけを写し、位置合わせは pairing に持つ（相手が ★ お気に入りのスイングなら、そのスイング自身の位置合わせを壊さない）
            var partner = right
            partner.video.phases = newValue.phases
            partner.video.candidates = newValue.candidates
            partner.video.lowConfidence = newValue.lowConfidence
            partner.video.slowFactor = newValue.slowFactor
            store.update(partner)
            var clip = left
            clip.pairing = Pairing(partnerID: right.id, transformOf: newValue, pairedAt: left.pairing?.pairedAt ?? Date())
            store.update(clip)
            updateVideos()
        }
        .onChange(of: controller.settings) { _, settings in
            store.playback = settings   // 次に開く比較も同じ設定から始める
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
                asset: side == .mine ? mineAsset : modelAsset,
                side: side)
        }
    }

    private func updateVideos() {
        controller.updateVideos(mine: mine, model: model)
    }

    private func editPhases(_ side: VideoSide) {
        controller.pause()
        editingSide = side
    }
}
