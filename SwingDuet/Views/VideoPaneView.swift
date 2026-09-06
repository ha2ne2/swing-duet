import SwiftUI
import AVFoundation

/// 1本の動画の表示ペイン。
/// 初期表示は検出した人物（`config.focusRect`）が収まるように自動で拡大する。ピンチで拡大縮小（ピンチした位置を中心に）、
/// ドラッグで位置合わせでき、拡大率と位置は自動フィットからの相対値として、指を離した時点で config に確定・保存される。
struct VideoPaneView: View {
    let player: AVPlayer
    @Binding var config: VideoConfig
    let side: ReferenceSide
    /// ラベルに添える名前（登録済みお手本の名前など）
    var title: String? = nil
    /// ラベルをタップしたとき（動画を選び直す）
    let onTapTitle: () -> Void

    /// 進行中のジェスチャーを反映した表示用の変換（指を離すと nil に戻り、確定値 config に従う）
    @GestureState private var live: Transform? = nil

    private static let scaleRange: ClosedRange<Double> = 0.5...4.0
    /// 自動フィットで人物の周りに空ける余白（人物範囲の幅・高さに対する割合）
    private static let focusMargin = 0.15

    var body: some View {
        GeometryReader { geo in
            let fit = Self.autoFit(config: config, paneSize: geo.size)
            let shown = live ?? fit.adjusted(by: config)
            ZStack {
                Color.black
                PlayerLayerView(player: player)
                    .scaleEffect(shown.scale)
                    .offset(shown.offset)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(transformGesture(fit: fit, paneSize: geo.size))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(side.label)の動画")
        .accessibilityValue(transformText)
        .accessibilityIdentifier("pane.\(side.rawValue)")
        .overlay(alignment: .topLeading) {
            Button(action: onTapTitle) {
                HStack(spacing: 4) {
                    Text(title.map { "\(side.label) · \($0)" } ?? side.label)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .frame(minHeight: 44)   // タッチ領域
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(side.label)の動画を選び直す")
            .accessibilityValue(title ?? "")
            .padding(.horizontal, 6)
            .padding(.trailing, 50)   // 右上のリセットボタンと重ねない
        }
        .overlay(alignment: .topTrailing) {
            Button {
                config.scale = 1
                config.offsetX = 0
                config.offsetY = 0
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("拡大と位置を自動フィットに戻す")
            .padding(6)
        }
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

    /// 自動フィット：検出した人物の範囲（focusRect）が余白付きでペインに収まる変換。範囲が無ければ等倍・中央。
    /// 縮小はしない（人物が画面いっぱいなら等倍のまま）。映像の端がペインに入って黒帯が出る手前で位置を止める
    private static func autoFit(config: VideoConfig, paneSize: CGSize) -> Transform {
        guard let focus = config.focusRect, focus.width > 0, focus.height > 0, config.videoAspect > 0,
              paneSize.width > 0, paneSize.height > 0 else { return .identity }

        // resizeAspect で表示される映像の大きさ（pt）
        let videoWidth = min(paneSize.width, paneSize.height * config.videoAspect)
        let videoHeight = videoWidth / config.videoAspect
        let padded = focus.insetBy(dx: -focusMargin * focus.width, dy: -focusMargin * focus.height)
        let scale = min(
            paneSize.width / (padded.width * videoWidth),
            paneSize.height / (padded.height * videoHeight),
            scaleRange.upperBound)
        guard scale > 1 else { return .identity }

        // 人物範囲の中心をペイン中心へ（Vision 座標は左下原点なので y は反転）
        let dx = (padded.midX - 0.5) * videoWidth * scale
        let dy = (0.5 - padded.midY) * videoHeight * scale
        let maxX = max(0, (videoWidth * scale - paneSize.width) / 2)
        let maxY = max(0, (videoHeight * scale - paneSize.height) / 2)
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
