import SwiftUI

/// 1 本の動画の表示ペイン。
/// 初期表示は検出した人物（`config.focusRect`）が収まるように自動で拡大する。ピンチで拡大縮小（ピンチした位置を中心に）、
/// ドラッグで位置合わせでき、拡大率と位置は自動フィットからの相対値として、指を離した時点で config に確定・保存される。
/// 部位の軌跡（`config.jointTrails`）は `showTrails` のとき映像と同じ変換で重ねる（`JointTrailOverlay`）。
/// 軌跡がまだ無い（または古い部位の組の）クリップは `ComparisonView` が作らせるので、その間は「替える」の下に「作成中」を出す。
/// この動画への操作は動画の上に重ねる。右上に「替える」（動画を選び直す）、下端中央に「フェーズ調整」
struct VideoPaneView: View {
    let controller: PlaybackController
    @Binding var config: VideoConfig
    let side: VideoSide
    /// クリップの表示名と倍率（VoiceOver と UI テストが「替える」の値として読む。画面には出さない）
    let title: String
    /// 「替える」をタップしたとき（動画を選び直す）
    let onSwap: () -> Void
    /// 「フェーズ調整」をタップしたとき
    let onEditPhases: () -> Void

    /// 進行中のジェスチャーを反映した表示用の変換（指を離すと nil に戻り、確定値 config に従う）
    @GestureState private var live: Transform? = nil
    /// 部位の軌跡を動画に重ねるか（ステージ右上のボタンで切り替える。アプリ全体で 1 つ）
    @AppStorage(JointTrailOverlay.isEnabledKey) private var showTrails = false
    /// 隠している部位の組（ステージ右上の「…」で切り替える）
    @AppStorage(JointTrailOverlay.hiddenPartsKey) private var hiddenParts = 0

    private static let scaleRange: ClosedRange<Double> = 0.5...4.0
    /// 自動フィットで人物の周りに空ける余白（人物範囲の幅・高さに対する割合）
    private static let focusMargin = 0.15

    var body: some View {
        GeometryReader { geo in
            let fit = Self.autoFit(config: config, paneSize: geo.size)
            let shown = live ?? fit.adjusted(by: config)
            ZStack {
                Color.black
                PlayerLayerView(player: controller.player(for: side))
                    .scaleEffect(shown.scale)
                    .offset(shown.offset)
                if let trails = trailsToDraw, let videoRect = Self.videoRect(config: config, paneSize: geo.size) {
                    TrailLayer(
                        trails: trails, parts: TrailPartGroup.shownParts(hidden: hiddenParts),
                        phases: config.phases, controller: controller, side: side,
                        videoRect: videoRect, scale: shown.scale, offset: shown.offset)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(transformGesture(fit: fit, paneSize: geo.size))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(side.label)の動画")
        .accessibilityValue(transformText)
        .accessibilityIdentifier("pane.\(side.rawValue)")
        .overlay(alignment: .topTrailing) {
            // NOTE: 「作成中」は「替える」の下に積む。ペインは画面の半分の幅しかないので、上端中央に置くと
            //       ポートレートでは「替える」と必ず重なる。中央に出すと、軌跡ができるまでの数十秒（Vision の
            //       人物追跡を 1 本ずつ順に走らせる）ずっと被写体を隠してしまう
            VStack(alignment: .trailing, spacing: 4) {
                PaneSwapButton(side: side, title: title, onSwap: onSwap)
                if isBuildingTrails {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("軌跡を作成中…")
                    }
                    .paneChip(touchTarget: false)
                    .padding(.horizontal, 6)   // 「替える」と右端をそろえる
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pane.\(side.rawValue).buildingTrails")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isBuildingTrails)
        }
        .overlay(alignment: .bottom) {
            Button(action: onEditPhases) {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text("フェーズ調整")
                }
                .paneChip()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(side.label)のフェーズ調整")
            .accessibilityIdentifier("pane.\(side.rawValue).editPhases")
        }
    }

    /// いま描ける軌跡（表示がオフか、まだ作られていなければ nil）
    private var trailsToDraw: JointTrails? {
        guard showTrails, let trails = config.jointTrails, trails.isCurrent else { return nil }
        return trails
    }

    /// 表示はオンだが軌跡がまだ無い（`ComparisonView` が作らせている最中）
    private var isBuildingTrails: Bool {
        showTrails && config.jointTrails?.isCurrent != true
    }

    /// 自動フィットに対する拡大率と位置（VoiceOver の読み上げと UI テストの検証に使う）
    private var transformText: String {
        String(format: "x%.2f (%.0f, %.0f)", config.scale, config.offsetX, config.offsetY)
    }

    // MARK: - 表示変換

    /// 拡大率と、ペイン中心からのずれ（pt）
    private struct Transform {
        var scale: Double
        var offset: CGSize

        /// 等倍・中央（自動フィットしないときの表示）
        static let identity = Transform(scale: 1, offset: .zero)

        /// 保存された相対値（自動フィットに対する倍率とずれ）を加えた変換
        func adjusted(by config: VideoConfig) -> Transform {
            Transform(
                scale: scale * config.scale,
                offset: CGSize(width: offset.width + config.offsetX, height: offset.height + config.offsetY))
        }

        /// ピンチによる拡大縮小。ピンチ開始位置 anchor の下にある映像の点が動かないようにオフセットも補正する。
        /// 映像の点 p は「ペイン中心 + p × 拡大率 + オフセット」に表示されるので、anchor を固定すると
        /// 新オフセット = (anchor − 中心) × (1 − 比) + 旧オフセット × 比（比 = 新拡大率 ÷ 旧拡大率）
        func magnified(by magnification: CGFloat, anchor: UnitPoint, paneSize: CGSize) -> Transform {
            var result = self
            result.scale = min(max(scale * magnification, scaleRange.lowerBound), scaleRange.upperBound)
            let ratio = result.scale / scale
            let dx = (anchor.x - 0.5) * paneSize.width
            let dy = (anchor.y - 0.5) * paneSize.height
            result.offset = CGSize(
                width: dx * (1 - ratio) + offset.width * ratio,
                height: dy * (1 - ratio) + offset.height * ratio)
            return result
        }

        func translated(by translation: CGSize) -> Transform {
            var result = self
            result.offset.width += translation.width
            result.offset.height += translation.height
            return result
        }
    }

    /// 等倍・中央（resizeAspect）で表示される映像の位置（ペイン座標・pt）。縦横比が分からなければ nil
    private static func videoRect(config: VideoConfig, paneSize: CGSize) -> CGRect? {
        guard config.videoAspect > 0, paneSize.width > 0, paneSize.height > 0 else { return nil }
        let width = min(paneSize.width, paneSize.height * config.videoAspect)
        let height = width / config.videoAspect
        return CGRect(x: (paneSize.width - width) / 2, y: (paneSize.height - height) / 2, width: width, height: height)
    }

    /// 自動フィット：検出した人物の範囲（focusRect）が余白付きでペインに収まる変換。範囲が無ければ等倍・中央。
    /// 縮小はしない（人物が画面いっぱいなら等倍のまま）。映像の端がペインに入って黒帯が出る手前で位置を止める
    private static func autoFit(config: VideoConfig, paneSize: CGSize) -> Transform {
        guard let focus = config.focusRect, focus.width > 0, focus.height > 0,
              let video = videoRect(config: config, paneSize: paneSize) else { return .identity }

        let padded = focus.insetBy(dx: -focusMargin * focus.width, dy: -focusMargin * focus.height)
        let scale = min(
            paneSize.width / (padded.width * video.width),
            paneSize.height / (padded.height * video.height),
            scaleRange.upperBound)
        guard scale > 1 else { return .identity }

        // 人物範囲の中心をペイン中心へ（Vision 座標は左下原点なので y は反転）
        let dx = (padded.midX - 0.5) * video.width * scale
        let dy = (0.5 - padded.midY) * video.height * scale
        let maxX = max(0, (video.width * scale - paneSize.width) / 2)
        let maxY = max(0, (video.height * scale - paneSize.height) / 2)
        return Transform(
            scale: scale,
            offset: CGSize(width: min(max(-dx, -maxX), maxX), height: min(max(-dy, -maxY), maxY)))
    }

    // MARK: - ジェスチャー

    /// ピンチ（拡大縮小）とドラッグ（移動）。ピンチ中はドラッグを無視する
    /// （2 本指のうち 1 本目の動きがドラッグとして拾われ、ピンチの中心がずれてしまうため）
    private func transformGesture(fit: Transform, paneSize: CGSize) -> some Gesture {
        DragGesture()
            .simultaneously(with: MagnifyGesture())
            .updating($live) { value, state, _ in
                state = Self.transform(for: value, base: fit.adjusted(by: config), paneSize: paneSize)
            }
            .onEnded { value in
                let result = Self.transform(for: value, base: fit.adjusted(by: config), paneSize: paneSize)
                // 自動フィットからの相対値で保存する（ペインの大きさが変わっても人物基準の見え方を保つため）
                config.scale = result.scale / fit.scale
                config.offsetX = result.offset.width - fit.offset.width
                config.offsetY = result.offset.height - fit.offset.height
            }
    }

    private static func transform(
        for value: SimultaneousGesture<DragGesture, MagnifyGesture>.Value,
        base: Transform,
        paneSize: CGSize
    ) -> Transform {
        if let pinch = value.second {
            return base.magnified(by: pinch.magnification, anchor: pinch.startAnchor, paneSize: paneSize)
        }
        if let drag = value.first {
            return base.translated(by: drag.translation)
        }
        return base
    }
}

/// 軌跡に再生位置を渡すだけの入れ物。
/// NOTE: `commonTime` を読む View をここだけに閉じ込める。ペイン本体で読むと、再生中は毎 tick ペイン全体
///       （プレーヤーとジェスチャー）が作り直される
private struct TrailLayer: View {
    let trails: JointTrails
    let parts: [BodyPart]
    let phases: PhaseSet
    let controller: PlaybackController
    let side: VideoSide
    let videoRect: CGRect
    let scale: Double
    let offset: CGSize

    var body: some View {
        JointTrailOverlay(
            trails: trails,
            parts: parts,
            phases: phases,
            now: controller.sync.videoTime(at: controller.commonTime, for: side),
            videoRect: videoRect,
            scale: scale,
            offset: offset)
    }
}
