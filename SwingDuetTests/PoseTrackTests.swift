import Testing
import Foundation
import CoreGraphics
@testable import SwingDuet

/// 追跡結果の下ごしらえ（手首のメディアン・範囲の切り出し）を固定する。
/// どちらもフェーズ検出の手前に必ず通る（動画の解析・撮影中の窓・切り出した 1 球の仮の解析）
struct PoseTrackTests {

    private func track(_ wrists: [CGPoint?], from start: Double = 0) -> PoseTrack {
        PoseTrack(frames: wrists.enumerated().map { i, wrist in
            PoseFrame(time: start + Double(i) / 30, wrist: wrist)
        })
    }

    // MARK: - 手首のメディアン

    @Test func medianFilterRemovesASingleFrameSpikeAndKeepsTheEnds() {
        let line = (0..<5).map { CGPoint(x: 0.1 * Double($0), y: 0.5) }
        var wrists: [CGPoint?] = line
        wrists[2] = CGPoint(x: 0.2, y: 0.9)   // 1 コマだけ飛ぶ
        let filtered = track(wrists).medianFilteredWrists().frames.map(\.wrist)
        #expect(filtered[2]?.y == 0.5)                       // 飛びは消える
        #expect(filtered[0] == line[0] && filtered[4] == line[4])   // 端はそのまま
    }

    @Test func medianFilterSkipsFramesNextToAGapAndShortTracks() {
        var wrists: [CGPoint?] = (0..<5).map { CGPoint(x: 0.1 * Double($0), y: 0.5) }
        wrists[1] = nil
        let filtered = track(wrists).medianFilteredWrists().frames.map(\.wrist)
        #expect(filtered[1] == nil)                    // 欠けは埋めない
        #expect(filtered[2] == wrists[2])              // 欠けが隣にある点はそのまま
        #expect(track([CGPoint(x: 0, y: 0), nil].map { $0 }).medianFilteredWrists().frames.count == 2)   // 3 コマ未満はそのまま
    }

    /// メディアンは x と y を別々に取るので、出力は元のどの点とも違う座標になりうる（承知の上：軌跡の平滑化が後段にある）
    @Test func medianIsTakenPerAxis() {
        let wrists: [CGPoint?] = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 0.5)]
        let filtered = track(wrists).medianFilteredWrists().frames.map(\.wrist)
        #expect(filtered[1] == CGPoint(x: 0.5, y: 0.5))
    }

    // MARK: - 範囲の切り出し

    @Test func slicingShiftsTimesSoTheRangeStartsAtZero() {
        let sliced = track((0..<30).map { CGPoint(x: 0.01 * Double($0), y: 0.5) }).sliced(to: 0.2...0.5)
        #expect(sliced.frames.first?.time == 0.2 - 0.2)
        #expect(abs((sliced.frames.last?.time ?? 0) - 0.3) < 1e-9)
        #expect(sliced.frames.count == 10)   // 0.2〜0.5 秒（30fps で 10 コマ）
        #expect(sliced.frames.first?.wrist == CGPoint(x: 0.06, y: 0.5))   // 中身は元のまま
    }

    @Test func slicingOutsideTheTrackGivesAnEmptyTrack() {
        #expect(track([CGPoint(x: 0, y: 0)]).sliced(to: 10...20).frames.isEmpty)
    }
}
