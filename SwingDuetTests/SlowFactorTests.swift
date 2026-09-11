import Testing
@testable import SwingDuet

/// 動画の速さの推定（ダウンスイング長からの倍率）と、ユーザーの選択との優先を固定する
struct SlowFactorTests {

    /// 境目は 0.52 / 1.04 / 2.08 / 4.2 / 8.3 秒で、実速寄りに丸める
    @Test func estimateFromDownswingDurationIsBiasedTowardRealSpeed() {
        #expect(SlowFactor.estimate(downswingDuration: 0) == 1)
        #expect(SlowFactor.estimate(downswingDuration: 0.3) == 1)
        #expect(SlowFactor.estimate(downswingDuration: 0.5) == 1)
        #expect(SlowFactor.estimate(downswingDuration: 0.55) == 2)
        #expect(SlowFactor.estimate(downswingDuration: 1.0) == 2)
        #expect(SlowFactor.estimate(downswingDuration: 1.2) == 4)
        #expect(SlowFactor.estimate(downswingDuration: 2.0) == 4)
        #expect(SlowFactor.estimate(downswingDuration: 2.4) == 8)
        #expect(SlowFactor.estimate(downswingDuration: 4.9) == 16)   // YouTube のスーパースロー
        #expect(SlowFactor.estimate(downswingDuration: 10) == 32)
        #expect(SlowFactor.estimate(downswingDuration: 100) == 32)
    }

    @Test func untouchedFallbackPhasesGiveNoEstimateButEditedPhasesDo() {
        var config = VideoConfig(fileName: "x.mp4", duration: 30, frameRate: 30, phases: .fallback(duration: 30))
        #expect(config.estimatedSlowFactor == 1)                 // 検出失敗の仮のフェーズ（ダウンスイング 3 秒）からは推定しない
        config.phases = PhaseSet(address: 0.3, top: 13.7, impact: 18.6, finish: 25.7)
        #expect(config.estimatedSlowFactor == 16)                // 手で置けば推定が出る
        #expect(config.effectiveSlowFactor == 16)
        config.slowFactor = 8
        #expect(config.effectiveSlowFactor == 8)                 // 選んだ値が優先
    }
}
