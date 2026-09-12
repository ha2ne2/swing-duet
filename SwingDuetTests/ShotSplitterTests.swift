import Testing
import Foundation
@testable import SwingDuet

/// 長い動画を 1 球ずつに分ける `ShotSplitter` と、範囲を切り出した解析結果（`SwingAnalysisResult.sliced`）を固定する
struct ShotSplitterTests {

    /// アドレス a から 1.5 秒のスイング候補。`rise` / `peak` で振り切りの大きさを、`score` で組の中の採点を与える
    private func candidate(at a: Double, rise: Double = 1.5, peak: Double = 5, score: Double = 1) -> SwingCandidate {
        SwingCandidate(
            phases: PhaseSet(address: a, top: a + 0.9, impact: a + 1.2, finish: a + 1.5),
            rise: rise, peakSpeed: peak, estimated: [], score: score)
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    /// 素振り（小さい）の 3 秒後に本番（大きい）：1 つのショットになり、範囲は本番の前後だけ
    @Test func practiceSwingBeforeTheRealOneIsNotCutOut() {
        let practice = candidate(at: 2, rise: 0.8, peak: 2, score: 0.5)
        let real = candidate(at: 6.5, score: 1.0)
        let shots = ShotSplitter.shots(candidates: [practice, real], duration: 20)
        #expect(shots.count == 1)
        #expect(shots[0].swing == real)
        #expect(near(shots[0].range.lowerBound, 6.5 - ShotSplitter.leadIn))
        #expect(near(shots[0].range.upperBound, 8.0 + ShotSplitter.leadOut))
    }

    /// 自動ティーアップで本番が 5 秒おきに続く：同じ組でも振り切りが同程度なら両方とも本番として残す（範囲は重ねない）
    @Test func twoFullSwingsCloseTogetherAreBothKept() {
        let first = candidate(at: 10, peak: 12, score: 0.9)
        let second = candidate(at: 16.5, peak: 11, score: 0.85)   // 前のフィニッシュ（11.5）から 5 秒後
        let shots = ShotSplitter.shots(candidates: [first, second], duration: 30)
        #expect(shots.map(\.swing) == [first, second])
        #expect(shots[0].range.upperBound <= shots[1].range.lowerBound)
    }

    /// 間が空いた本番どうしは別のショット。範囲は動画の中に収まり、先頭のショットは 0 から
    @Test func separateShotsAreCutWithMargins() {
        let shots = ShotSplitter.shots(candidates: [candidate(at: 1), candidate(at: 15), candidate(at: 29)], duration: 30)
        #expect(shots.count == 3)
        #expect(near(shots[0].range.lowerBound, 0))
        #expect(near(shots[1].range.lowerBound, 13.5))
        #expect(near(shots[1].range.upperBound, 18.0))
        #expect(near(shots[2].range.upperBound, 30))
    }

    /// 単独の候補が他の組の代表より明らかに小さければ素振りとみなして捨てる。比べる相手が無ければ残す
    @Test func lonelySmallSwingIsDroppedOnlyWhenOthersExist() {
        let small = candidate(at: 20, rise: 0.5, peak: 1.5, score: 0.3)
        let shots = ShotSplitter.shots(candidates: [candidate(at: 1), candidate(at: 10), small], duration: 30)
        #expect(shots.count == 2)
        #expect(!shots.contains { $0.swing == small })

        let alone = ShotSplitter.shots(candidates: [small], duration: 30)
        #expect(alone.count == 1)
    }

    /// 切り出した 1 球のクリップ：解析結果は範囲の分、撮影日時は範囲の先頭だけ後ろ、相手は元のまま、id は渡したもの
    @Test func shotClipCarriesTheSlicedAnalysisAndThePairing() {
        var s = SwingDetectorTests.Series()
        s.hold(0, 8.0)
        s.ramp(to: 1.6, 0.7)
        s.ramp(to: -0.1, 0.25)
        s.ramp(to: 1.5, 0.4)
        s.hold(1.5, 1.0)
        let result = SwingAnalysisResult(duration: s.time, frameRate: s.fps, videoAspect: 0.56, pose: s.track, candidates: s.detect())
        let shot = result.shots[0]
        let partner = UUID()
        let take = Clip(role: .swing, shotAt: Date(timeIntervalSince1970: 1_700_000_000), assetID: "take", video: .placeholder(fileName: ""),
                        analysis: .pending, pairing: Pairing(partnerID: partner))
        let clip = Clip.shot(from: take, range: shot.range, sliced: result.sliced(to: shot.range), source: .library(localID: "shot-1", cloudID: nil), id: take.id)
        #expect(clip.id == take.id)
        #expect(clip.isAnalyzed)
        #expect(clip.source == .library(localID: "shot-1", cloudID: nil))
        #expect(clip.pairing?.partnerID == partner)
        #expect(near(clip.shotAt!.timeIntervalSince1970, 1_700_000_000 + shot.range.lowerBound))
        #expect(near(clip.video.duration, shot.range.upperBound - shot.range.lowerBound))
        #expect(abs(clip.video.phases.impact - (shot.swing.phases.impact - shot.range.lowerBound)) < 0.12)
    }

    /// 合成した系列：本番 2 回（8 秒空ける）。ショットは 2 つになり、切り出した範囲だけを解析し直すとフェーズが先頭基準にずれる
    @Test func slicedResultShiftsPhasesToTheCutRange() {
        var s = SwingDetectorTests.Series()
        for _ in 0..<2 {
            s.hold(0, 2.0)
            s.ramp(to: 1.6, 0.7)
            s.ramp(to: -0.1, 0.25)
            s.ramp(to: 1.5, 0.4)
            s.hold(1.5, 0.5)
            s.ramp(to: 0, 0.8)
            s.hold(0, 4.0)
        }
        let result = SwingAnalysisResult(duration: s.time, frameRate: s.fps, videoAspect: 1, pose: s.track, candidates: s.detect())
        #expect(result.candidates.count == 2)
        let shots = result.shots
        #expect(shots.count == 2)

        let second = result.sliced(to: shots[1].range)
        #expect(near(second.duration, shots[1].range.upperBound - shots[1].range.lowerBound))
        #expect(second.chosen != nil)
        #expect(abs(second.phases.impact - (shots[1].swing.phases.impact - shots[1].range.lowerBound)) < 0.12)
        #expect(!second.lowConfidence)
    }
}
