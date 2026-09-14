import Testing
import Foundation
@testable import SwingDuet

struct TrailFitTests {
    private func points() -> [TrailPoint] {
        (0...100).map { i in
            let t = Double(i) / 100
            return TrailPoint(time: t, point: CGPoint(x: 0.3 + 0.1 * t, y: 0.3 + 0.3 * t - 0.05 * t * t))
        }
    }

    /// 全部位が動くスイング。肩・股関節は手より小さく、向きを変えながら動く
    private func movingSamples(count: Int = 150) -> [JointTrailSample] {
        (0...count).map { i -> JointTrailSample in
            let t = Double(i) / 100
            func circle(_ center: CGPoint, _ radius: Double, _ turns: Double) -> CGPoint {
                CGPoint(x: center.x + radius * cos(t * turns), y: center.y + radius * sin(t * turns))
            }
            return JointTrailSample(
                time: t,
                hands: CGPoint(x: 0.3 + 0.08 * t, y: 0.4 + 0.1 * sin(t * 4)),
                head: circle(CGPoint(x: 0.5, y: 0.8), 0.02, 2),
                leftShoulder: circle(CGPoint(x: 0.4, y: 0.6), 0.05, 3),
                rightShoulder: circle(CGPoint(x: 0.6, y: 0.6), 0.05, 3),
                leftHip: circle(CGPoint(x: 0.4, y: 0.3), 0.03, 2),
                rightHip: circle(CGPoint(x: 0.6, y: 0.3), 0.03, 2))
        }
    }

    @Test func reproducesSmoothMotionAndKeepsEndpoints() throws {
        let input = points()
        let fit = try #require(TrailFit(points: input, aspect: 1.8, bodyScale: 0.3))
        for p in input {
            let actual = try #require(fit.point(at: p.time))
            #expect(actual.distance(to: p.point) < 1e-8)
        }
        #expect(fit.point(at: -0.1) == nil)
        #expect(fit.point(at: 1.1) == nil)
    }

    @Test func rejectsShortInvalidAndDisconnectedInput() {
        let p = points()
        #expect(TrailFit(points: Array(p.prefix(5)), aspect: 1, bodyScale: 0.3) == nil)
        var broken = p
        broken[40].time = broken[39].time
        #expect(TrailFit(points: broken, aspect: 1, bodyScale: 0.3) == nil)
        broken = p
        broken[40].point.x = .nan
        #expect(TrailFit(points: broken, aspect: 1, bodyScale: 0.3) == nil)
        #expect(TrailFit(points: p, aspect: 0, bodyScale: 0.3) == nil)
        let gap = Array(p.prefix(20)) + Array(p.suffix(20))
        #expect(TrailFit(points: gap, aspect: 1, bodyScale: 0.3) == nil)
    }

    @Test func suppressesAnIsolatedFalseDip() throws {
        let clean = points()
        var noisy = clean
        noisy[50].point.y -= 0.12
        let fit = try #require(TrailFit(points: noisy, aspect: 1, bodyScale: 0.3))
        let actual = try #require(fit.point(at: 0.5))
        #expect(actual.distance(to: clean[50].point) < 0.01)
    }

    /// 測定が形に対して粗いと 6 個の制御点では形を追えない。そのときは近似を作らず通常の描画に任せる
    @Test func skipsTheFitWhenTheCurveCannotRepresentTheMeasurements() throws {
        func zigzag(amplitude: Double) -> [TrailPoint] {
            (0..<14).map { i in
                TrailPoint(time: Double(i) * 0.05,
                           point: CGPoint(x: 0.4 + 0.01 * Double(i), y: 0.5 + (i % 2 == 0 ? amplitude : -amplitude)))
            }
        }
        #expect(TrailFit(points: zigzag(amplitude: 0.05), aspect: 1, bodyScale: 0.3) == nil)
        #expect(TrailFit(points: zigzag(amplitude: 0.002), aspect: 1, bodyScale: 0.3) != nil)
    }

    @Test func theDrawnCurveKeepsItsHistoryAndPutsTheTipOnTheSameCurve() throws {
        let fit = try #require(TrailFit(points: points(), aspect: 1, bodyScale: 0.3))
        let early = fit.points(until: 0.431)
        let later = fit.points(until: 0.8)
        #expect(Array(early.dropLast()) == Array(later.prefix(early.count - 1)))
        #expect(early.last?.point == fit.point(at: 0.431))
        #expect(fit.points(until: 0.431) == early)
        #expect(fit.points(until: 3).last?.time == 1)
        #expect(fit.points(until: -1).isEmpty)
    }

    @Test func phaseChangesRebuildTheRangeWithoutChangingSavedSamples() throws {
        let samples = points().map { p in
            JointTrailSample(time: p.time, hands: p.point,
                             leftShoulder: CGPoint(x: 0.4, y: 0.6), rightShoulder: CGPoint(x: 0.6, y: 0.6),
                             leftHip: CGPoint(x: 0.4, y: 0.3), rightHip: CGPoint(x: 0.6, y: 0.3))
        }
        let trails = JointTrails(samples: samples)
        let a = TrailFit.prepare(trails: trails, phases: PhaseSet(address: 0, top: 0.5, impact: 0.8, finish: 1), aspect: 1)
        let b = TrailFit.prepare(trails: trails, phases: PhaseSet(address: 0.1, top: 0.7, impact: 0.8, finish: 1), aspect: 1)
        let key = TrailFit.Key(part: .hands, stroke: 0, section: 0)
        #expect(try #require(a[key]).end == 0.5)
        #expect(try #require(b[key]).start == 0.1)
        #expect(try #require(b[key]).end == 0.7)
        #expect(trails.samples == samples)
        // 動かない部位は 1 点に潰れているので近似を作らない（近似しても見た目が変わらない）
        #expect(a[TrailFit.Key(part: .leftHip, stroke: 0, section: 0)] == nil)
    }

    @Test func fitsAllThreeSectionsThroughFinishWithSharedEndpoints() throws {
        let phases = PhaseSet(address: 0, top: 0.5, impact: 0.8, finish: 1.5)
        let fits = TrailFit.prepare(trails: JointTrails(samples: movingSamples()), phases: phases, aspect: 1)
        func key(_ section: Int) -> TrailFit.Key { .init(part: .hands, stroke: 0, section: section) }
        let back = try #require(fits[key(0)])
        let down = try #require(fits[key(1)])
        let follow = try #require(fits[key(2)])
        #expect(back.end == down.start)
        #expect(down.end == follow.start)
        #expect(back.point(at: back.end) == down.point(at: down.start))
        #expect(down.point(at: down.end) == follow.point(at: follow.start))
        #expect(follow.end == 1.5)
        #expect(follow.point(at: 1.4) != nil)
        #expect(follow.points(until: 2).last?.time == 1.5)
    }

    /// 手だけでなく、動いている部位はすべて近似する。別々の曲線として引けること（鍵に部位が入っていること）も確かめる
    @Test func fitsEveryMovingPartSeparately() throws {
        let phases = PhaseSet(address: 0, top: 0.5, impact: 0.8, finish: 1.5)
        let fits = TrailFit.prepare(trails: JointTrails(samples: movingSamples()), phases: phases, aspect: 1)
        for part in BodyPart.allCases {
            for section in 0..<3 {
                #expect(fits[TrailFit.Key(part: part, stroke: 0, section: section)] != nil,
                        "\(part) の区間 \(section) が近似されていない")
            }
        }
        let leftHip = try #require(fits[TrailFit.Key(part: .leftHip, stroke: 0, section: 0)])
        let rightHip = try #require(fits[TrailFit.Key(part: .rightHip, stroke: 0, section: 0)])
        #expect(leftHip.point(at: 0.25) != rightHip.point(at: 0.25))
    }

    @Test func sectionsKeepMissingIntervalsAndShareOnlyExistingBoundaryPoints() {
        let phases = PhaseSet(address: 0, top: 0.5, impact: 0.8, finish: 1.5)
        let p = [0.2, 0.4, 0.6, 0.9, 1.1].map { TrailPoint(time: $0, point: CGPoint(x: 0.5, y: 0.5)) }
        let sections = TrailFit.sections(of: p, phases: phases)
        #expect(sections.map(\.index) == [0, 1, 2])
        #expect(sections[0].points.last == sections[1].points.first)
        #expect(sections[1].points.last == sections[2].points.first)
        let late = TrailFit.sections(of: Array(p.suffix(2)), phases: phases)
        #expect(late.map(\.index) == [2])
    }
}
