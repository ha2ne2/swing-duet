import Testing
import Foundation
@testable import SwingDuet

/// 撮影中に候補を本番か素振りかに決める `LiveShotJudge` の待ち方と素振りの扱いを固定する
struct LiveShotJudgeTests {

    /// アドレス a から 1.5 秒のスイング候補（フィニッシュ a + 1.5）
    private func candidate(at a: Double, rise: Double = 1.5, peak: Double = 5) -> SwingCandidate {
        SwingCandidate(phases: PhaseSet(address: a, top: a + 0.9, impact: a + 1.2, finish: a + 1.5), rise: rise, peakSpeed: peak, estimated: [])
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    /// 1 本の候補はフィニッシュから 6 秒待って本番と決まり、範囲は前後の余白付き
    @Test func singleSwingIsDecidedSixSecondsAfterFinish() {
        var judge = LiveShotJudge()
        let swing = candidate(at: 10)
        let isNew = judge.observe(swing)
        #expect(isNew)
        #expect(judge.verdicts(at: 11.5 + 5.9).isEmpty)
        let verdicts = judge.verdicts(at: 11.5 + 6.0)
        #expect(verdicts.count == 1)
        #expect(verdicts[0].shot?.swing == swing)
        #expect(near(verdicts[0].shot?.range.lowerBound ?? 0, 10 - ShotSplitter.leadIn))
        #expect(near(verdicts[0].shot?.range.upperBound ?? 0, 11.5 + ShotSplitter.leadOut))
        #expect(judge.verdicts(at: 30).isEmpty)
    }

    /// 素振り（小さい）の 3 秒後に本番：本番のフィニッシュから 6 秒待って、素振りは素振り・本番は本番と決まる
    @Test func practiceSwingBeforeTheRealOneIsJudgedAsPractice() {
        var judge = LiveShotJudge()
        let practice = candidate(at: 2, rise: 0.8, peak: 2)
        let real = candidate(at: 6.5)
        judge.observe(practice)
        #expect(judge.verdicts(at: 3.5 + 5).isEmpty)   // 素振りのフィニッシュから 5 秒：本番がまだ来るかもしれない
        judge.observe(real)
        #expect(judge.verdicts(at: 8.0 + 5.9).isEmpty)
        let verdicts = judge.verdicts(at: 8.0 + 6.0)
        #expect(verdicts.map(\.candidate) == [practice, real])
        #expect(verdicts.map { $0.shot != nil } == [false, true])
        #expect(near(verdicts[1].shot?.range.lowerBound ?? 0, 6.5 - ShotSplitter.leadIn))
    }

    /// 自動ティーアップで本番が 5 秒おきに続く：同じ組でも両方本番で、範囲は重ならない
    @Test func twoFullSwingsCloseTogetherAreBothShots() {
        var judge = LiveShotJudge()
        let first = candidate(at: 10, peak: 12)
        let second = candidate(at: 16.5, peak: 11)
        judge.observe(first)
        judge.observe(second)
        let shots = judge.verdicts(at: 18.0 + 6.0).compactMap(\.shot)
        #expect(shots.map(\.swing) == [first, second])
        #expect(shots[0].range.upperBound <= shots[1].range.lowerBound)
    }

    /// 2 球決まった後は、中央値と同程度の候補はフィニッシュから 1 秒で決まる。小さい候補は 6 秒待ち、中央値と比べて素振りになる
    @Test func afterTwoShotsSimilarSwingsAreDecidedQuicklyAndSmallOnesArePractice() {
        var judge = LiveShotJudge()
        judge.observe(candidate(at: 0))
        judge.observe(candidate(at: 20))
        #expect(judge.verdicts(at: 21.5 + 6).compactMap(\.shot).count == 2)

        let third = candidate(at: 40)
        judge.observe(third)
        #expect(judge.verdicts(at: 41.5 + 0.9).isEmpty)
        #expect(judge.verdicts(at: 41.5 + 1.0).compactMap(\.shot).map(\.swing) == [third])

        let small = candidate(at: 60, rise: 0.5, peak: 1.5)
        judge.observe(small)
        #expect(judge.verdicts(at: 61.5 + 1.0).isEmpty)
        let verdicts = judge.verdicts(at: 61.5 + 6.0)
        #expect(verdicts.count == 1 && verdicts[0].shot == nil && verdicts[0].candidate == small)
        #expect(judge.pending.isEmpty)
    }

    /// 手が動いている間（次のスイングの途中かもしれない）は待つ
    @Test func decisionWaitsWhileHandsAreMoving() {
        var judge = LiveShotJudge()
        judge.observe(candidate(at: 10))
        #expect(judge.verdicts(at: 20, inMotion: true).isEmpty)
        #expect(judge.verdicts(at: 20, inMotion: false).count == 1)
    }

    /// 同じスイング（インパクトが近い）は新しい方に置き換わって「新しい候補」にならず、決めた後に来たものは無視される
    @Test func observingTheSameSwingAgainReplacesItAndDecidedOnesAreIgnored() {
        var judge = LiveShotJudge()
        let first = judge.observe(candidate(at: 10))
        #expect(first)
        var refined = candidate(at: 10.1)
        refined.phases.finish = 11.8
        let replaced = judge.observe(refined)
        #expect(!replaced)
        #expect(judge.pending == [refined])

        #expect(judge.verdicts(at: 11.8 + 6).count == 1)
        let again = judge.observe(candidate(at: 10.2))
        #expect(!again)
        #expect(judge.pending.isEmpty)
    }

    /// 止めたときは待たずに全部決める
    @Test func flushDecidesEverythingImmediately() {
        var judge = LiveShotJudge()
        judge.observe(candidate(at: 10))
        judge.observe(candidate(at: 30))
        #expect(judge.flush(at: 31.6).compactMap(\.shot).count == 2)
        #expect(judge.pending.isEmpty)
    }
}
