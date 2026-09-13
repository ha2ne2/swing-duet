import Testing
import CoreGraphics
@testable import SwingDuet

/// 撮影中の追跡結果からスイング候補・構え・静かさを読む `LiveDetector` と、区切りファイルを閉じる `SegmentPlanner` を固定する
struct LiveDetectorTests {

    /// 腰 y = 0.4、首 y = 0.6 の人物のフレーム。h は手の高さ（腰 0・首 1）。nil は手首が見えない
    private func frame(at t: Double, hand h: Double?, root: CGPoint = CGPoint(x: 0.5, y: 0.4),
                       bounds: CGRect? = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8)) -> PoseFrame {
        PoseFrame(time: t, wrist: h.map { CGPoint(x: 0.5, y: 0.4 + 0.2 * $0) }, root: bounds == nil ? nil : root,
                  neck: bounds == nil ? nil : CGPoint(x: root.x, y: root.y + 0.2), bodyBounds: bounds)
    }

    /// 15fps で `seconds` 秒ぶんのフレームを足し、構えの結果を集める
    private func feed(_ detector: inout LiveDetector, from start: Double, seconds: Double, hand: Double? = 0,
                      root: CGPoint = CGPoint(x: 0.5, y: 0.4), bounds: CGRect? = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8)) -> [LiveDetector.StanceEvent] {
        var events: [LiveDetector.StanceEvent] = []
        let n = Int((seconds * LiveDetector.sampleRate).rounded())
        for i in 0..<n {
            let t = start + Double(i) / LiveDetector.sampleRate
            if let stance = detector.add(frame(at: t, hand: hand, root: root, bounds: bounds)).stance { events.append(stance) }
        }
        return events
    }

    // MARK: - 構え

    /// 全身が枠に入ったまま 2 秒静止すると「見えた」が 1 回だけ出る
    @Test func standingStillInsideTheFrameIsSeenOnce() {
        var detector = LiveDetector()
        #expect(feed(&detector, from: 0, seconds: 1.9).isEmpty)
        #expect(feed(&detector, from: 1.9, seconds: 0.3) == [.seen])
        #expect(feed(&detector, from: 2.2, seconds: 5).isEmpty)
    }

    /// 足が画面の下端に掛かっていれば「切れている」
    @Test func bodyTouchingTheBottomEdgeIsCutOff() {
        var detector = LiveDetector()
        let cut = CGRect(x: 0.3, y: 0.0, width: 0.4, height: 0.8)
        #expect(feed(&detector, from: 0, seconds: 2.5, bounds: cut) == [.cutOff])
    }

    /// 歩いている間（腰が動く）は判定せず、止まってから 2 秒で判定する
    @Test func walkingDelaysTheStanceJudgement() {
        var detector = LiveDetector()
        var events: [LiveDetector.StanceEvent] = []
        for i in 0..<45 {   // 3 秒かけて右へ歩く
            let t = Double(i) / LiveDetector.sampleRate
            if let e = detector.add(frame(at: t, hand: 0, root: CGPoint(x: 0.2 + 0.01 * Double(i), y: 0.4))).stance { events.append(e) }
        }
        #expect(events.isEmpty)
        #expect(feed(&detector, from: 3, seconds: 2.2, root: CGPoint(x: 0.65, y: 0.4)) == [.seen])
    }

    /// 人物がいなくなって 3 秒経てば、戻ってきたときにもう一度判定する
    @Test func stanceIsJudgedAgainAfterThePersonLeaves() {
        var detector = LiveDetector()
        #expect(feed(&detector, from: 0, seconds: 2.5) == [.seen])
        #expect(feed(&detector, from: 2.5, seconds: 3.5, hand: nil, bounds: nil).isEmpty)
        #expect(!detector.isPersonVisible(at: 5.9))
        #expect(feed(&detector, from: 6, seconds: 2.5) == [.seen])
        #expect(detector.isPersonVisible(at: 8.4))
    }

    // MARK: - 静かさと動き

    /// 手が低く止まっていれば静か。高ければ動いている
    @Test func quietAndMotionFollowTheHandHeight() {
        var detector = LiveDetector()
        _ = feed(&detector, from: 0, seconds: 1, hand: 0)
        #expect(detector.isQuiet(at: 1))
        #expect(!detector.inMotion(at: 1))
        _ = feed(&detector, from: 1, seconds: 0.5, hand: 1.2)
        #expect(!detector.isQuiet(at: 1.5))
        #expect(detector.inMotion(at: 1.5))
        _ = feed(&detector, from: 1.5, seconds: 1.2, hand: 0)
        #expect(detector.isQuiet(at: 2.7))
        #expect(!detector.inMotion(at: 2.7))
        // 手首が見えなければ静か
        _ = feed(&detector, from: 2.7, seconds: 1, hand: nil)
        #expect(detector.isQuiet(at: 3.7))
    }

    // MARK: - スイングの検出

    /// 本番 1 回：フィニッシュの 1 秒後に候補として登録され（ここで仮に保存して合図）、6 秒後に本番と決まる。範囲の追跡（仮の解析用）は先頭が 0
    @Test func fullSwingIsRegisteredAfterOneSecondAndDecidedAfterSix() {
        var detector = LiveDetector()
        var registered: [SwingCandidate] = []
        var verdicts: [LiveShotJudge.Verdict] = []
        var t = 0.0
        func step(_ h: Double?) {
            let update = detector.add(frame(at: t, hand: h))
            registered += update.registered
            verdicts += update.verdicts
            t += 1 / LiveDetector.sampleRate
        }
        func hold(_ h: Double, _ seconds: Double) { for _ in 0..<Int((seconds * LiveDetector.sampleRate).rounded()) { step(h) } }
        func ramp(to h: Double, from: Double, _ seconds: Double) {
            let n = Int((seconds * LiveDetector.sampleRate).rounded())
            for i in 1...n { step(from + (h - from) * Double(i) / Double(n)) }
        }
        hold(0, 3.0); let address = t
        ramp(to: 1.6, from: 0, 0.7)
        ramp(to: -0.1, from: 1.6, 0.25)
        ramp(to: 1.5, from: -0.1, 0.4); let finish = t
        hold(1.5, 0.6)
        ramp(to: 0, from: 1.5, 0.8)
        #expect(registered.isEmpty)   // フィニッシュから 1 秒はまだ（下ろしている間は手が高い）
        hold(0, 4.5)
        #expect(registered.count == 1)   // 候補として登録された（仮に保存する）
        #expect(verdicts.isEmpty)        // フィニッシュから 6 秒はまだ
        hold(0, 2.5)
        #expect(verdicts.count == 1)
        guard let shot = verdicts[0].shot else { Issue.record("本番と決まっていない"); return }
        #expect(shot.swing == registered[0] || abs(shot.swing.phases.impact - registered[0].phases.impact) < LiveShotJudge.sameSwingTolerance)
        #expect(abs(shot.swing.phases.address - address) < 0.3)
        #expect(abs(shot.swing.phases.finish - finish) < 0.3)
        #expect(verdicts[0].decidedAt >= shot.swing.phases.finish + LiveShotJudge.waitAfterFinish)
        #expect(detector.lastFinish != nil)

        // 登録した時点の範囲は判定の範囲と同じ余白で、その範囲の追跡は先頭が 0 の 1 本の動画として検出し直せる
        let range = LiveDetector.range(of: registered[0])
        #expect(abs(range.lowerBound - (registered[0].phases.address - ShotSplitter.leadIn)) < 1e-9)
        let track = detector.track(in: range)
        #expect(track.frames.first.map { $0.time < 0.1 } == true)
        #expect(abs((track.frames.last?.time ?? 0) - (range.upperBound - range.lowerBound)) < 0.1)
        #expect(SwingDetector.detect(track: track, duration: range.upperBound - range.lowerBound).count == 1)
    }

    // MARK: - 区切り

    /// ショットのフィニッシュから後ろの余白（1.5 秒）が書き終わった直後（1.6 秒）に、手が静かなら閉じる。閉じた後は同じフィニッシュでは閉じない
    @Test func segmentClosesRightAfterTheLeadOutWhenQuiet() {
        var planner = SegmentPlanner()
        #expect(!planner.shouldClose(at: 11.5, lastFinish: 10, quiet: true))
        #expect(!planner.shouldClose(at: 12, lastFinish: 10, quiet: false))
        #expect(planner.shouldClose(at: 11.6, lastFinish: 10, quiet: true))
        #expect(planner.shouldClose(at: 12, lastFinish: 10, quiet: true))
        planner.didClose(at: 12)
        #expect(!planner.shouldClose(at: 13, lastFinish: 10, quiet: true))
        #expect(planner.shouldClose(at: 22, lastFinish: 20, quiet: true))
    }

    /// ショットが無くても 60 秒で閉じる（静かなとき）。静かにならなければ 75 秒で閉じる
    @Test func segmentClosesAtSixtySecondsOrSeventyFiveWithoutQuiet() {
        var planner = SegmentPlanner()
        #expect(!planner.shouldClose(at: 59, lastFinish: nil, quiet: true))
        #expect(planner.shouldClose(at: 60, lastFinish: nil, quiet: true))
        #expect(!planner.shouldClose(at: 70, lastFinish: nil, quiet: false))
        #expect(planner.shouldClose(at: 75, lastFinish: nil, quiet: false))
    }
}
