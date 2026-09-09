import Testing
import CoreGraphics
@testable import SwingDuet

/// 合成した手の高さの系列で `SwingDetector` の境界条件を固定する。
/// 腰 y = 0.4、首 y = 0.6（体の大きさ 0.2）で、手首は x = 0.5 のまま上下だけ動く。高さ h の手首は y = 0.4 + 0.2h
struct SwingDetectorTests {

    /// 手の高さの系列を 30fps で組み立てる。nil は手首が見えないフレーム
    struct Series {
        let fps = 30.0
        private(set) var heights: [Double?] = []
        /// 次に足すフレームの時刻
        var time: Double { Double(heights.count) / fps }

        /// 高さ h で seconds 秒止まる
        mutating func hold(_ h: Double, _ seconds: Double) {
            heights += Array(repeating: h, count: Int((seconds * fps).rounded()))
        }
        /// 直前の高さから h まで seconds 秒かけて一定速度で動く
        mutating func ramp(to h: Double, _ seconds: Double) {
            let from = (heights.last { $0 != nil } ?? nil) ?? 0
            let n = Int((seconds * fps).rounded())
            for i in 1...n { heights.append(from + (h - from) * Double(i) / Double(n)) }
        }
        /// seconds 秒間、手首が見えない
        mutating func gap(_ seconds: Double) {
            heights += Array(repeating: nil, count: Int((seconds * fps).rounded()))
        }

        var track: PoseTrack {
            let times = heights.indices.map { Double($0) / fps }
            return PoseTrack(
                times: times,
                points: heights.map { $0.map { CGPoint(x: 0.5, y: 0.4 + 0.2 * $0) } },
                roots: times.map { _ in CGPoint(x: 0.5, y: 0.4) },
                necks: times.map { _ in CGPoint(x: 0.5, y: 0.6) },
                bodyBounds: times.map { _ in CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8) })
        }

        func detect() -> [SwingCandidate] {
            SwingDetector.detect(track: track, duration: time)
        }
    }

    /// 2 フレーム以内
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.07 }

    @Test func fullSwingIsDetectedWithAllPhasesObserved() {
        var s = Series()
        s.hold(0, 0.5); let addressEnd = s.time
        s.ramp(to: 1.6, 0.7); let top = s.time - 1 / s.fps
        s.ramp(to: -0.1, 0.25); let impact = s.time - 1 / s.fps
        s.ramp(to: 1.5, 0.4); let finishStart = s.time
        s.hold(1.5, 0.5)

        let candidates = s.detect()
        #expect(candidates.count == 1)
        let c = candidates[0]
        #expect(near(c.phases.address, addressEnd - 0.1))
        #expect(near(c.phases.top, top))
        #expect(near(c.phases.impact, impact))
        #expect(c.phases.finish >= finishStart && c.phases.finish <= finishStart + 0.35)
        #expect(c.estimated.isEmpty)
        #expect(near(c.rise, 1.6))
    }

    @Test func practiceSwingAndRealSwingAreBothCandidatesAndTheRealOneScoresHigher() {
        var s = Series()
        // 素振り：小さく上げて、フィニッシュもそれなりに高い
        s.hold(0, 0.5)
        s.ramp(to: 1.0, 0.5); s.ramp(to: 0, 0.3); s.ramp(to: 0.9, 0.3); s.hold(0.9, 0.3); s.ramp(to: 0, 0.3)
        // 本番
        s.hold(0, 0.5)
        s.ramp(to: 1.6, 0.7); s.ramp(to: -0.1, 0.25); let impact = s.time - 1 / s.fps
        s.ramp(to: 1.5, 0.4); s.hold(1.5, 0.5)

        let candidates = s.detect()
        #expect(candidates.count == 2)
        let chosen = candidates.max { $0.score < $1.score }
        #expect(chosen.map { near($0.phases.impact, impact) } == true)
        #expect(candidates[0].score < candidates[1].score)
    }

    @Test func holdAtTopIsNotMistakenForAddressAndTopIsTheEndOfTheHold() {
        var s = Series()
        s.hold(0, 0.5); let addressEnd = s.time
        s.ramp(to: 1.6, 0.6)
        s.hold(1.6, 2.0); let holdEnd = s.time
        s.ramp(to: 0, 0.3); let impact = s.time - 1 / s.fps
        s.ramp(to: 1.5, 0.4); s.hold(1.5, 0.5)

        let candidates = s.detect()
        #expect(candidates.count == 1)
        let c = candidates[0]
        #expect(near(c.phases.address, addressEnd - 0.1))
        #expect(near(c.phases.top, holdEnd))
        #expect(near(c.phases.impact, impact))
        #expect(c.estimated.isEmpty)
    }

    @Test func occludedTopAndImpactAreEstimatedWhenWristsReappearHigh() {
        var s = Series()
        s.hold(0, 0.5); let addressEnd = s.time
        s.ramp(to: 0.4, 0.3)
        s.gap(0.8); let reappear = s.time
        s.hold(1.3, 1 / s.fps); s.ramp(to: 1.6, 0.3); s.hold(1.6, 0.5)

        let candidates = s.detect()
        #expect(candidates.count == 1)
        let c = candidates[0]
        let address = c.phases.address
        #expect(near(address, addressEnd - 0.1))
        #expect(near(c.phases.impact, reappear))
        #expect(near(c.phases.top, address + 0.75 * (c.phases.impact - address)))
        #expect(c.estimated == [.top, .impact])
    }

    @Test func occludedDescentKeepsObservedTopAndMarksImpactEstimated() {
        var s = Series()
        s.hold(0, 0.5)
        s.ramp(to: 0.8, 0.5); let lastSeenHigh = s.time - 1 / s.fps
        s.gap(0.7)
        s.hold(0.1, 1 / s.fps); s.ramp(to: -0.1, 0.1); let lowest = s.time - 1 / s.fps
        s.ramp(to: 0.8, 0.3); s.hold(0.8, 0.5)

        let candidates = s.detect()
        #expect(candidates.count == 1)
        let c = candidates[0]
        #expect(near(c.phases.top, lastSeenHigh))
        #expect(near(c.phases.impact, lowest))
        #expect(c.estimated == [.impact])
    }

    @Test func rehearsalFromTopBackToAddressIsNotASwing() {
        var s = Series()
        s.hold(0, 0.5); s.ramp(to: 1.5, 1.0); s.hold(1.5, 1.0); s.ramp(to: 0, 1.5); s.hold(0, 0.5)
        #expect(s.detect().isEmpty)
    }

    @Test func raisingTheClubWithoutSwingingIsNotASwing() {
        var s = Series()
        s.hold(0, 0.5); s.ramp(to: 1.5, 0.5); s.hold(1.5, 1.0)
        #expect(s.detect().isEmpty)
    }

    @Test func tooFewSamplesGiveNoCandidates() {
        var s = Series()
        s.hold(0, 0.1)
        #expect(s.detect().isEmpty)
    }
}
