import Testing
import CoreGraphics
import SwiftUI
@testable import SwingDuet

/// 軌跡の描画の下ごしらえ（トップでの色の切り替えと、点の間引き）を固定する
struct JointTrailOverlayTests {

    /// 時刻だけが意味を持つ点列（位置は使わない）
    private func stroke(times: [Double]) -> [TrailPoint] {
        times.map { TrailPoint(time: $0, point: CGPoint(x: $0, y: 0)) }
    }

    // MARK: - トップでの分割

    @Test func splitJoinsTheTwoHalvesAtTheFirstPointAfterTop() {
        let parts = JointTrailOverlay.split(stroke(times: [0, 1, 2, 3, 4]), atTop: 2.5)
        #expect(parts.count == 2)
        #expect(parts[0].afterTop == false)
        #expect(parts[0].points.map(\.time) == [0, 1, 2, 3])   // 継ぎ目が切れないよう、前半はトップ以降の最初の点まで伸ばす
        #expect(parts[1].afterTop == true)
        #expect(parts[1].points.map(\.time) == [3, 4])
    }

    @Test func splitReturnsOneHalfWhenTheStrokeIsAllOnOneSide() {
        let before = JointTrailOverlay.split(stroke(times: [0, 1, 2]), atTop: 9)
        #expect(before.count == 1 && before[0].afterTop == false)
        let after = JointTrailOverlay.split(stroke(times: [3, 4, 5]), atTop: 1)
        #expect(after.count == 1 && after[0].afterTop == true)
    }

    @Test func splitDropsAHalfThatWouldBeASinglePoint() {
        // トップの手前が 1 点だけ：前半は「その点 + トップ以降の最初の点」で 2 点になり、後半は 3 点
        let parts = JointTrailOverlay.split(stroke(times: [0, 1, 2, 3]), atTop: 0.5)
        #expect(parts.map(\.points.count) == [2, 3])
        // トップ以降が 1 点だけ：後半は 1 点なので落とす
        #expect(JointTrailOverlay.split(stroke(times: [0, 1, 2]), atTop: 1.5).map(\.afterTop) == [false])
    }

    // MARK: - 間引き

    @Test func thinningKeepsShortStrokesAsTheyAre() {
        let points = stroke(times: (0..<80).map(Double.init))
        #expect(JointTrailOverlay.thinned(points).count == points.count)
    }

    @Test func thinningCapsTheCountAndAlwaysKeepsTheLastPoint() {
        let points = stroke(times: (0..<600).map(Double.init))
        let thinned = JointTrailOverlay.thinned(points)
        #expect(thinned.count <= 81)                       // 上限 80 ＋ 末尾の 1 点
        #expect(thinned.first?.time == 0)
        #expect(thinned.last?.time == 599)                 // 線の終わりは必ず残す
        #expect(thinned.map(\.time) == thinned.map(\.time).sorted())
    }

    // MARK: - 曲線

    /// 曲線は点を通らない（近くを通る）が、線の始まりと先だけは点にちょうど届く。
    /// 先が届かないと、線の終わりと現在位置の丸がずれる
    @Test func curveStartsAndEndsOnThePointsButPassesNearTheOnesBetween() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 2), CGPoint(x: 2, y: 0), CGPoint(x: 3, y: 2)]
        var visited: [CGPoint] = []
        JointTrailOverlay.curve(through: points).forEach { element in
            switch element {
            case .move(let to): visited.append(to)
            case .curve(let to, _, _): visited.append(to)
            case .line(let to): visited.append(to)
            default: break
            }
        }
        #expect(visited.first == points.first)
        #expect(visited.last == points.last)
        // 山（1,2）は通らずに内側を抜ける
        let nearPeak = visited.filter { abs($0.x - 1) < 0.5 }.map(\.y).max() ?? 0
        #expect(nearPeak < 2.0)
        #expect(nearPeak > 1.0)
    }

    @Test func curveOfTwoPointsIsAStraightLine() {
        var visited: [CGPoint] = []
        JointTrailOverlay.curve(through: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]).forEach { element in
            if case .line(let to) = element { visited.append(to) }
        }
        #expect(visited == [CGPoint(x: 1, y: 1)])
    }

    // MARK: - 再生位置までの線

    /// 通ったところだけを描き、間引きで消えた分の先はいまの位置につなぐ
    @Test func playedStopsAtTheCurrentTimeAndReachesIt() {
        let points = (0...10).map { TrailPoint(time: Double($0) / 10, point: CGPoint(x: Double($0) / 10, y: 0.5)) }
        let played = JointTrailOverlay.played(points, until: 0.45, tip: CGPoint(x: 0.45, y: 0.5))
        #expect(played.count == 6)                             // 0.0〜0.4 の 5 点 ＋ いまの位置
        #expect(played.last == TrailPoint(time: 0.45, point: CGPoint(x: 0.45, y: 0.5)))
        #expect(played.dropLast().allSatisfy { $0.time <= 0.45 })
    }

    /// 線を全部通り過ぎていれば、いまの位置は足さない（線の先は最後の点のまま）
    @Test func playedDoesNotExtendPastTheEndOfTheStroke() {
        let points = (0...10).map { TrailPoint(time: Double($0) / 10, point: CGPoint(x: Double($0) / 10, y: 0.5)) }
        let played = JointTrailOverlay.played(points, until: 5, tip: CGPoint(x: 0.9, y: 0.9))
        #expect(played.count == points.count)
        #expect(played.last == points.last)
    }

    /// まだ 1 点しか通っていない線は描かない（線が引けず、丸だけが浮くのを避ける）
    @Test func playedIsEmptyUntilTheStrokeHasTwoPoints() {
        let points = (0...10).map { TrailPoint(time: Double($0) / 10, point: CGPoint(x: Double($0) / 10, y: 0.5)) }
        #expect(JointTrailOverlay.played(points, until: 0.05, tip: nil).isEmpty)
        #expect(JointTrailOverlay.played(points, until: -1, tip: CGPoint(x: 0, y: 0)).isEmpty)
    }
}
