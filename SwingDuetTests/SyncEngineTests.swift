import Testing
@testable import SwingDuet

/// 共通タイムラインが実秒であること（基準側の速さで戻す）と、両側の速度倍率を固定する
struct SyncEngineTests {

    /// 実速の自分（30fps）：バック 0.8 / ダウン 0.3 / フォロー 0.6 秒
    private let mine = VideoConfig(
        fileName: "mine.mov", duration: 3, frameRate: 30,
        phases: PhaseSet(address: 0.5, top: 1.3, impact: 1.6, finish: 2.2))

    /// 1/8 の焼き込みスローのお手本（30fps）：動画上でバック 6.4 / ダウン 2.0 / フォロー 4.0 秒（実時間 0.8 / 0.25 / 0.5）
    private var model: VideoConfig {
        var config = VideoConfig(
            fileName: "model.mov", duration: 20, frameRate: 30,
            phases: PhaseSet(address: 2, top: 8.4, impact: 10.4, finish: 14.4))
        config.slowFactor = 8
        return config
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func slowModelAsReferenceIsPlayedBackInRealSeconds() {
        let sync = SyncEngine(mine: mine, model: model, reference: .model)
        #expect(near(sync.commonDuration, 12.4 / 8))
        #expect(near(sync.commonTime(of: .top), 0.8))
        #expect(near(sync.commonTime(of: .impact), 1.05))
        #expect(near(sync.rateMultiplier(for: .model, in: .downswing), 8))        // 基準側は速さそのもの
        #expect(near(sync.rateMultiplier(for: .mine, in: .downswing), 0.3 / 0.25)) // 非基準側は実時間の区間長の比
        #expect(near(sync.referenceFrameDuration, 1.0 / 240))                     // 1 コマ = 1/30 動画秒 = 1/240 実秒
    }

    @Test func realSpeedMineAsReferenceStretchesTheSlowModelWithoutUsingItsFactor() {
        let sync = SyncEngine(mine: mine, model: model, reference: .mine)
        #expect(near(sync.commonDuration, 1.7))
        #expect(near(sync.rateMultiplier(for: .mine, in: .downswing), 1))
        #expect(near(sync.rateMultiplier(for: .model, in: .downswing), 2.0 / 0.3))
        // ダウンスイングの中間（共通 0.95 秒）はお手本の 8.4 + 1.0 秒
        #expect(near(sync.videoTime(at: 0.95, for: .model), 9.4))
        #expect(near(sync.referenceFrameDuration, 1.0 / 30))
    }

    @Test func bothSidesSlowUseOnlyTheReferenceFactor() {
        var slowMine = mine
        slowMine.slowFactor = 4   // 実際は 1/4 で撮った自分（動画上 0.8 / 0.3 / 0.6 = 実時間 0.2 / 0.075 / 0.15）
        let sync = SyncEngine(mine: slowMine, model: model, reference: .mine)
        #expect(near(sync.commonDuration, 1.7 / 4))
        #expect(near(sync.rateMultiplier(for: .mine, in: .downswing), 4))
        #expect(near(sync.rateMultiplier(for: .model, in: .downswing), 2.0 / 0.075))   // お手本の 8 は区間長の比に含まれる
    }
}
