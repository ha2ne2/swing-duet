import SwiftUI
import AVFoundation

/// 1本の動画の表示ペイン。
/// ピンチで拡大縮小（ピンチした位置を中心に）、ドラッグで位置合わせ、ボタンで左右反転（レフティ・撮影側の違いを吸収）。
/// 拡大率と位置は指を離した時点で config に確定し、プロジェクトに保存される。
struct VideoPaneView: View {
    let player: AVPlayer
    @Binding var config: VideoConfig
    let side: ReferenceSide

    /// 進行中のジェスチャーを反映した表示用の変換（指を離すと nil に戻り、確定値 config に従う）
    @GestureState private var live: Transform? = nil

    private static let scaleRange: ClosedRange<Double> = 0.5...4.0

    var body: some View {
        GeometryReader { geo in
            let shown = live ?? Transform(config: config)
            ZStack {
                Color.black
                PlayerLayerView(player: player)
                    .scaleEffect(x: (config.mirrored ? -1 : 1) * shown.scale, y: shown.scale)
                    .offset(shown.offset)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(transformGesture(paneSize: geo.size))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(side.label)の動画")
        .accessibilityValue(transformText)
        .accessibilityIdentifier("pane.\(side.rawValue)")
        .overlay(alignment: .topLeading) {
            Text(side.label)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Button {
                    config.mirrored.toggle()
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                        .foregroundStyle(config.mirrored ? Color.accentColor : .white)
                }
                Button {
                    config.scale = 1
                    config.offsetX = 0
                    config.offsetY = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.white)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(8)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }

    /// 保存済みの拡大率と位置（VoiceOver の読み上げと UI テストの検証に使う）
    private var transformText: String {
        String(format: "x%.2f (%.0f, %.0f)", config.scale, config.offsetX, config.offsetY)
    }

    // MARK: - ジェスチャー

    /// 表示変換：拡大率と、ペイン中心からのずれ（pt）
    private struct Transform {
        var scale: Double
        var offset: CGSize

        init(config: VideoConfig) {
            scale = config.scale
            offset = CGSize(width: config.offsetX, height: config.offsetY)
        }

        /// ピンチによる拡大縮小。ピンチ開始位置 anchor の下にある映像の点が動かないようにオフセットも補正する。
        /// 映像の点 p は「ペイン中心 + p × 拡大率 + オフセット」に表示されるので、anchor を固定すると
        /// 新オフセット = (anchor − 中心) × (1 − 比) + 旧オフセット × 比（比 = 新拡大率 ÷ 旧拡大率。左右反転でも同じ式）
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

    /// ピンチ（拡大縮小）とドラッグ（移動）。ピンチ中はドラッグを無視する
    /// （2 本指のうち 1 本目の動きがドラッグとして拾われ、ピンチの中心がずれてしまうため）
    private func transformGesture(paneSize: CGSize) -> some Gesture {
        DragGesture()
            .simultaneously(with: MagnifyGesture())
            .updating($live) { value, state, _ in
                state = Self.transform(for: value, base: Transform(config: config), paneSize: paneSize)
            }
            .onEnded { value in
                let result = Self.transform(for: value, base: Transform(config: config), paneSize: paneSize)
                config.scale = result.scale
                config.offsetX = result.offset.width
                config.offsetY = result.offset.height
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
