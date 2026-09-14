import SwiftUI
import AVFoundation

/// 動画を読み込み、2 本を再生するコントローラを作って比較画面へ渡す。
/// NOTE: View の再生成で AVPlayer が増えないよう、コントローラは init ではなく task で作る。
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
                            mine: left.video, model: right.video,
                            settings: store.playback)
                        guard !Task.isCancelled else { return }
                        loaded = (mine, model, controller)
                    } catch {
                        guard !Task.isCancelled else { return }
                        loadError = error.localizedDescription
                    }
                }
            }
        }
    }
}

/// 位置合わせは各ペインの保存先へ、フェーズは動画の持ち主へ書く。
/// 設定全体のコピーを保存せず、表示中に更新された解析結果を保つ。
private struct ComparisonContent: View {
    @EnvironmentObject private var store: ClipStore
    let left: Clip
    let right: Clip
    /// 解いた動画（フェーズ調整のプレビューに渡す）
    let mineAsset: AVAsset
    let modelAsset: AVAsset
    let controller: PlaybackController
    let onSelectVideo: (VideoSide) -> Void

    @State private var editingSide: VideoSide?
    /// 部位の軌跡を動画に重ねるか（ステージ右上のボタンで切り替える）。オンにしたとき、軌跡がまだ無いクリップには作らせる
    @AppStorage(JointTrailOverlay.isEnabledKey) private var showTrails = false

    private func clip(for side: VideoSide) -> Clip {
        let original = side == .mine ? left : right
        return store.clip(id: original.id) ?? original
    }

    private func transform(for side: VideoSide) -> Binding<PaneTransform> {
        Binding(
            get: {
                side == .mine ? clip(for: .mine).video.transform : clip(for: .mine).partnerTransform(for: right.id)
            },
            set: { value in
                if side == .mine {
                    store.setTransform(value, of: left.id)
                } else {
                    store.setPartnerTransform(value, of: left.id, partnerID: right.id)
                }
            })
    }

    var body: some View {
        VStack(spacing: 8) {
            // 動画ペイン（左右並び）
            HStack(spacing: 2) {
                ForEach(VideoSide.allCases) { side in
                    VideoPaneView(
                        controller: controller, config: clip(for: side).video, transform: transform(for: side),
                        side: side, title: clip(for: side).paneTitle,
                        onSwap: { onSelectVideo(side) }, onEditPhases: { editPhases(side) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            ControlPanelView(controller: controller)
        }
        // 同期の写像はフェーズと動画の速さだけで決まる。この画面での修正でも、撮影した球の解析し直しでも、変わったら作り直す
        .onChange(of: VideoSide.allCases.map { SyncEngine.Timing(clip(for: $0).video) }) { _, _ in
            controller.updateVideos(mine: clip(for: .mine).video, model: clip(for: .model).video)
        }
        .onChange(of: controller.settings) { _, settings in
            store.playback = settings   // 次に開く比較も同じ設定から始める
        }
        .onChange(of: showTrails, initial: true) { _, isOn in
            guard isOn else { return }
            store.requestTrails(of: left.id)
            store.requestTrails(of: right.id)
        }
        .task {
            await controller.playWhenReady()   // 開いたら自動で再生
        }
        .onDisappear {
            controller.pause()
        }
        .sheet(item: $editingSide) { side in
            PhaseEditView(
                config: clip(for: side).video,
                asset: side == .mine ? mineAsset : modelAsset,
                side: side) { phases, slowFactor in
                    store.setPhases(phases, slowFactor: slowFactor, of: clip(for: side).id)
                }
        }
    }

    private func editPhases(_ side: VideoSide) {
        controller.pause()
        editingSide = side
    }
}
