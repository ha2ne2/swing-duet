import Testing
@testable import SwingDuet

/// 共通タイムラインが実秒であること（基準側の速さで戻す）と、両側の速度倍率を固定する。
/// 同期しないときは伸縮せず、揃えるフェーズの瞬間だけ一致し、それぞれの速さで流れることを固定する
struct SyncEngineTests {

    /// 実速の自分（30fps・3 秒）：バック 0.8 / ダウン 0.3 / フォロー 0.6 秒
    private let mine = VideoConfig(
        fileName: "mine.mov", duration: 3, frameRate: 30,
        phases: PhaseSet(address: 0.5, top: 1.3, impact: 1.6, finish: 2.2))

    /// 1/8 の焼き込みスローのお手本（30fps・20 秒）：動画上でバック 6.4 / ダウン 2.0 / フォロー 4.0 秒（実時間 0.8 / 0.25 / 0.5）
    private var model: VideoConfig {
        var config = VideoConfig(
            fileName: "model.mov", duration: 20, frameRate: 30,
            phases: PhaseSet(address: 2, top: 8.4, impact: 10.4, finish: 14.4))
        config.slowFactor = 8
        return config
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    // MARK: - 基準あり

    @Test func slowModelAsReferenceIsPlayedBackInRealSeconds() {
        let sync = SyncEngine(mine: mine, model: model, basis: .model)
        #expect(near(sync.commonDuration, 12.4 / 8))
        #expect(near(sync.commonTime(of: .top, for: .model), 0.8))
        #expect(near(sync.commonTime(of: .top, for: .mine), 0.8))        // 同期しているときはフェーズの位置が両側で同じ
        #expect(near(sync.commonTime(of: .impact, for: .mine), 1.05))
        #expect(near(sync.rateMultiplier(for: .model, at: 0.9), 8))        // 基準側は速さそのもの
        #expect(near(sync.rateMultiplier(for: .mine, at: 0.9), 0.3 / 0.25)) // 非基準側は実時間の区間長の比（ダウンスイング）
        #expect(near(sync.frameStep, 1.0 / 240))                            // 1 コマ = 1/30 動画秒 = 1/240 実秒
    }

    @Test func realSpeedMineAsReferenceStretchesTheSlowModelWithoutUsingItsFactor() {
        let sync = SyncEngine(mine: mine, model: model, basis: .mine)
        #expect(near(sync.commonDuration, 1.7))
        #expect(near(sync.rateMultiplier(for: .mine, at: 0.95), 1))
        #expect(near(sync.rateMultiplier(for: .model, at: 0.95), 2.0 / 0.3))
        // ダウンスイングの中間（共通 0.95 秒）はお手本の 8.4 + 1.0 秒
        #expect(near(sync.videoTime(at: 0.95, for: .model), 9.4))
        #expect(near(sync.frameStep, 1.0 / 30))
    }

    @Test func bothSidesSlowUseOnlyTheReferenceFactor() {
        var slowMine = mine
        slowMine.slowFactor = 4   // 実際は 1/4 で撮った自分（動画上 0.8 / 0.3 / 0.6 = 実時間 0.2 / 0.075 / 0.15）
        let sync = SyncEngine(mine: slowMine, model: model, basis: .mine)
        #expect(near(sync.commonDuration, 1.7 / 4))
        #expect(near(sync.rateMultiplier(for: .mine, at: 0.25), 4))
        #expect(near(sync.rateMultiplier(for: .model, at: 0.25), 2.0 / 0.075))   // お手本の 8 は区間長の比に含まれる
    }

    // MARK: - 同期しない

    @Test func freeRunKeepsEachSideAtItsOwnRealSpeedAndAlignsOnlyTheAnchor() {
        let sync = SyncEngine(mine: mine, model: model, basis: .free, anchor: .address)
        // 早い方のアドレス（両方 0）から遅い方のフィニッシュ（自分 1.7 / お手本 1.55）まで
        #expect(near(sync.commonDuration, 1.7))
        #expect(near(sync.commonTime(of: .address, for: .model), 0))
        #expect(near(sync.commonTime(of: .impact, for: .mine), 1.1))
        #expect(near(sync.commonTime(of: .impact, for: .model), 1.05))      // お手本のダウンスイングは 0.05 秒短い
        #expect(near(sync.firstCommonTime(of: .impact), 1.05))
        #expect(near(sync.lastCommonTime(of: .impact), 1.1))
        #expect(near(sync.commonTime(of: .finish, for: .model), 1.55))
        // 伸縮しない：共通 1.0 秒は自分 0.5 + 1.0、お手本 2 + 1.0 × 8
        #expect(near(sync.videoTime(at: 1.0, for: .mine), 1.5))
        #expect(near(sync.videoTime(at: 1.0, for: .model), 10))
        // 倍率は常にその側の速さ。お手本はフィニッシュを過ぎても動画が続く限り流れる
        #expect(near(sync.rateMultiplier(for: .mine, at: 0.3), 1))
        #expect(near(sync.rateMultiplier(for: .model, at: 0.3), 8))
        #expect(near(sync.rateMultiplier(for: .model, at: 1.6), 8))
        #expect(near(sync.frameStep, 1.0 / 240))                           // 細かい方（お手本の 1/240 実秒）
    }

    @Test func freeRunAnchoredAtImpactShiftsTheShorterSwing() {
        var sync = SyncEngine(mine: mine, model: model, basis: .free, anchor: .impact)
        // インパクトまで自分 1.1 / お手本 1.05 秒なので、お手本のアドレスは 0.05 秒遅れて始まる
        #expect(near(sync.commonDuration, 1.7))
        #expect(near(sync.commonTime(of: .impact, for: .mine), 1.1))
        #expect(near(sync.commonTime(of: .impact, for: .model), 1.1))
        #expect(near(sync.commonTime(of: .address, for: .model), 0.05))
        #expect(near(sync.commonTime(of: .top, for: .mine), 0.8))
        #expect(near(sync.commonTime(of: .top, for: .model), 0.85))
        // 共通 0 秒はお手本のアドレスの 0.05 実秒（0.4 動画秒）手前
        #expect(near(sync.videoTime(at: 0, for: .model), 1.6))
        // 揃えるフェーズを替えるとそこで一致する
        sync.anchor = .top
        #expect(near(sync.commonTime(of: .top, for: .mine), sync.commonTime(of: .top, for: .model)))
        #expect(near(sync.commonTime(of: .impact, for: .model), sync.commonTime(of: .impact, for: .mine) - 0.05))
    }

    @Test func freeRunWaitsAtTheFirstFrameUntilTheFootageStarts() {
        var longFollow = mine
        longFollow.phases.finish = 2.9   // フォロー 1.3 秒
        let sync = SyncEngine(mine: longFollow, model: model, basis: .free, anchor: .finish)
        // 自分のアドレスはフィニッシュの 2.4 秒前、お手本は 1.55 秒前。お手本の動画は共通 0.6 秒（アドレスの 0.25 秒前 = 動画の先頭）から始まる
        #expect(near(sync.commonDuration, 2.4))
        #expect(near(sync.videoTime(at: 0, for: .model), 0))
        #expect(near(sync.rateMultiplier(for: .model, at: 0), 0))          // 先頭の絵のまま待つ
        #expect(near(sync.rateMultiplier(for: .model, at: 0.9), 8))
        #expect(near(sync.videoTime(at: 0.9, for: .model), 2.4))
        #expect(near(sync.rateMultiplier(for: .mine, at: 0), 1))
    }
}
