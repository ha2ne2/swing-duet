import SwiftUI

/// 共通タイムラインの1本のシークバー。
/// バックスイング / ダウンスイング / フォローを色分けし（凡例は出さない）、ドラッグで2本を同時にシークする。
struct SeekBarView: View {
    let controller: PlaybackController

    @State private var isScrubbing = false

    private var sync: SyncEngine { controller.sync }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // 区間の色分け
                HStack(spacing: 0) {
                    ForEach(SwingSegment.allCases) { segment in
                        Rectangle()
                            .fill(segment.color.opacity(
                                controller.loop.segment == nil || controller.loop.segment == segment
                                    ? 0.85 : 0.25))
                            .frame(width: segmentWidth(segment, totalWidth: width))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // フェーズ境界（トップ / インパクト）
                ForEach([SwingPhase.top, SwingPhase.impact], id: \.self) { phase in
                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 1.5)
                        .offset(x: x(for: sync.commonTime(of: phase), width: width))
                }

                // 再生ヘッド
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .frame(width: 4)
                    .shadow(radius: 2)
                    .offset(x: x(for: controller.commonTime, width: width) - 2)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            controller.beginScrub()
                        }
                        let t = Double(value.location.x / max(width, 1)) * sync.commonDuration
                        controller.scrub(to: t)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        controller.endScrub()
                    })
        }
        .frame(height: 28)
    }

    private func segmentWidth(_ segment: SwingSegment, totalWidth: CGFloat) -> CGFloat {
        let range = sync.commonRange(of: segment)
        let fraction = (range.upperBound - range.lowerBound) / sync.commonDuration
        return max(totalWidth * CGFloat(fraction), 0)
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        let fraction = min(max(time / sync.commonDuration, 0), 1)
        return width * CGFloat(fraction)
    }
}
