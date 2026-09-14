import SwiftUI

/// 共通時刻のシークとループ範囲の編集。
/// 同期中は1本、同期しないときは左右別の帯でフェーズを示す。つまみはフェーズからの整数コマに揃える。
struct SeekBarView: View {
    let controller: PlaybackController

    private static let barHeight: CGFloat = 28
    private static let handleWidth: CGFloat = 12
    /// スイング区間の外（アドレスより前・フィニッシュより後。同期しないときだけ幅がある）
    private static let outsideColor = Color(white: 0.3)
    /// つまみのドラッグを測るバーの座標系の名前
    private static let coordinateSpace = "seekBar"

    @State private var isScrubbing = false
    /// ドラッグ中のつまみの、つかんだ時点の端の位置（共通タイムライン上の秒）。指の移動量をここに足す
    /// （指の位置をそのまま使うと、つまみの中心と端の 6pt のずれで触った瞬間に 1 コマ跳ねる）
    @State private var dragFrom: Double?

    private var sync: SyncEngine { controller.sync }

    /// 区間を塗る帯を出す側（同期しているときは 1 本、同期しないときは自分・お手本の 2 本）
    private var bars: [VideoSide] { sync.basis == .free ? VideoSide.allCases : [.mine] }

    var body: some View {
        GeometryReader { geo in
            // つまみは範囲の外側に付くので、目盛りの両端をつまみの幅だけ空ける。範囲がスイング全体でもつまみが横の余白（16pt）を越えず、
            // 上下の操作と端がそろう
            let width = max(geo.size.width - 2 * Self.handleWidth, 0)
            let scale = TimeScale(duration: sync.commonDuration, width: width)
            let lower = scale.x(of: controller.loopRange.lowerBound)
            let upper = scale.x(of: controller.loopRange.upperBound)
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    VStack(spacing: 2) {
                        ForEach(bars) { side in
                            segmentBar(for: side, scale: scale)
                        }
                    }
                    // ループ範囲の外を沈める（スイング全体 / ループしないでは幅 0）
                    Color.black.opacity(0.6)
                        .frame(width: lower)
                    Color.black.opacity(0.6)
                        .frame(width: max(width - upper, 0))
                        .offset(x: upper)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Playhead(controller: controller, scale: scale)

                if controller.loop != nil {
                    // 範囲の枠（左右の縦棒がつまみ）と、つまみの中央の印
                    TrimFrame(lower: lower, upper: upper, handleWidth: Self.handleWidth, lineWidth: 1.5)
                        .fill(.white, style: FillStyle(eoFill: true))
                    ForEach(LoopRange.Bound.allCases, id: \.self) { bound in
                        Capsule()
                            .fill(Color(.darkGray))
                            .frame(width: 1.5, height: 12)
                            .offset(x: handleCenter(bound, lower: lower, upper: upper) - 0.75)
                    }
                }
            }
            .frame(width: width, height: Self.barHeight, alignment: .leading)
            // つまみの当たり（44pt）はバーからはみ出すので overlay に置き、バーの大きさに影響させない。
            // NOTE: overlay の暗黙の ZStack は子を「子の最大の大きさ」の中央に寄せるので、大きさの違う子を並べると小さい子がずれる。
            //       明示的な ZStack をバーの大きさに固定し、各子をバーの左端から置く
            .overlay(alignment: .leading) {
                if let range = controller.loop {
                    ZStack(alignment: .leading) {
                        ForEach(LoopRange.Bound.allCases, id: \.self) { bound in
                            handleHitArea(bound, edge: range[bound], lower: lower, upper: upper, scale: scale)
                        }
                    }
                    .frame(width: width, height: Self.barHeight, alignment: .leading)
                }
            }
            .padding(.horizontal, Self.handleWidth)
            .contentShape(Rectangle())   // つまみの分の余白もシークの当たりに含める
            .coordinateSpace(name: Self.coordinateSpace)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            controller.beginDrag()
                        }
                        // 指の位置は余白を含む座標なので、目盛りの左端を 0 にする（目盛りの外は scrub が端に収める）
                        controller.scrub(to: scale.time(atX: value.location.x - Self.handleWidth, clamping: false))
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        controller.endDrag()
                    })
        }
        .frame(height: Self.barHeight)
    }

    // MARK: - 帯

    /// その側の区間の色分けと、フェーズ境界（トップ / インパクト）の線
    private func segmentBar(for side: VideoSide, scale: TimeScale) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Self.outsideColor
                    .frame(width: scale.x(of: sync.commonTime(of: .address, for: side)))
                ForEach(SwingSegment.allCases) { segment in
                    let range = sync.commonRange(of: segment, for: side)
                    Rectangle()
                        .fill(segment.color.opacity(0.85))
                        .frame(width: max(scale.x(of: range.upperBound) - scale.x(of: range.lowerBound), 0))
                }
                Self.outsideColor
            }
            ForEach([SwingPhase.top, SwingPhase.impact], id: \.self) { phase in
                Rectangle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 1.5)
                    .offset(x: scale.x(of: sync.commonTime(of: phase, for: side)))
            }
        }
    }

    // MARK: - つまみ

    /// つまみの中心の x（枠の縦棒の中心。開始は範囲の左端の外側、終了は右端の外側）
    private func handleCenter(_ bound: LoopRange.Bound, lower: CGFloat, upper: CGFloat) -> CGFloat {
        bound == .start ? lower - Self.handleWidth / 2 : upper + Self.handleWidth / 2
    }

    /// つまみの当たり（見た目は `TrimFrame` の縦棒）。44pt 四方でバーの上下に 8pt はみ出す
    private func handleHitArea(_ bound: LoopRange.Bound, edge: LoopEdge, lower: CGFloat, upper: CGFloat, scale: TimeScale) -> some View {
        let time = bound == .start ? controller.loopRange.lowerBound : controller.loopRange.upperBound
        return Color.clear
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(x: handleCenter(bound, lower: lower, upper: upper) - 22)
            // 指の位置はバーの座標系で測る。つまみ自身の座標系だと、つまみが指に付いて動くたびに移動量が縮んで元に戻り、コマごとに往復して発振する
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { value in
                        if dragFrom == nil {
                            dragFrom = time
                            controller.beginDrag()
                        }
                        guard let dragFrom else { return }
                        controller.trim(bound, to: dragFrom + scale.time(movedBy: value.translation.width))
                    }
                    .onEnded { _ in
                        dragFrom = nil
                        controller.endDrag()
                    })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bound == .start ? "ループ開始" : "ループ終了")
            .accessibilityValue(edge.label)
            .accessibilityHint("上下にスワイプで 1 コマ")
            .accessibilityAdjustableAction { direction in
                controller.beginDrag()
                controller.trim(bound, to: time + (direction == .increment ? 1.0 : -1.0) * sync.frameStep)
                controller.endDrag()
            }
            .accessibilityIdentifier(bound == .start ? "seekBar.loopStart" : "seekBar.loopEnd")
    }

}

/// 再生ヘッド。
/// NOTE: `commonTime` を読む View をここだけに閉じ込める。バーの本体で読むと、再生中は毎 tick（最大 60Hz）
///       帯・枠・つまみの当たり（`DragGesture` を含む）まで作り直される。動くのはこの棒の位置だけ
private struct Playhead: View {
    let controller: PlaybackController
    let scale: TimeScale

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.white)
            .frame(width: 4)
            .shadow(radius: 2)
            .offset(x: scale.x(of: controller.commonTime) - 2)
    }
}

/// ループ範囲の枠。左右の太い縦棒（つまみ）と上下の細い線を 1 つの形にする（塗りは even-odd で内側を抜く）。
/// 別々の View で描くと画素への丸めがずれて、つまみと線の間に隙間が出る。`lower` / `upper` は範囲の左右の端の x で、縦棒はその外側に付く
private struct TrimFrame: Shape {
    var lower: CGFloat
    var upper: CGFloat
    var handleWidth: CGFloat
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let inner = max(upper - lower, 0)
        var path = Path(
            roundedRect: CGRect(x: lower - handleWidth, y: rect.minY, width: inner + 2 * handleWidth, height: rect.height),
            cornerRadius: 3)
        path.addRect(CGRect(x: lower, y: rect.minY + lineWidth, width: inner, height: rect.height - 2 * lineWidth))
        return path
    }
}
