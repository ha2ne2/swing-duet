import Testing
@testable import SwingDuet

/// ループ範囲の端（フェーズからのコマ数）の丸め・詰め・追従を固定する
struct LoopRangeTests {

    /// 実速の自分（30fps）：共通タイムラインでトップ 0.8 / インパクト 1.1 / 長さ 1.7 秒（1 コマ = 1/30 秒）
    private let mine = VideoConfig(
        fileName: "mine.mov", duration: 3, frameRate: 30,
        phases: PhaseSet(address: 0.5, top: 1.3, impact: 1.6, finish: 2.2))

    /// 1/8 の焼き込みスローのお手本（30fps。1 コマ = 1/240 実秒）
    private var model: VideoConfig {
        var config = VideoConfig(
            fileName: "model.mov", duration: 20, frameRate: 30,
            phases: PhaseSet(address: 2, top: 8.4, impact: 10.4, finish: 14.4))
        config.slowFactor = 8
        return config
    }

    private var sync: SyncEngine { SyncEngine(mine: mine, model: model, basis: .mine) }
    private let frame = 1.0 / 30

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func nearestEdgeRoundsToFramesFromTheNearestPhase() {
        #expect(sync.loopEdge(nearest: 0.8 - 3 * frame, as: .start) == LoopEdge(phase: .top, frames: -3))
        #expect(sync.loopEdge(nearest: 0.8 + 0.4 * frame, as: .start) == LoopEdge(phase: .top, frames: 0))   // 半コマ未満は 0 に丸まる
        #expect(sync.loopEdge(nearest: 1.0, as: .end) == LoopEdge(phase: .impact, frames: -3))              // インパクト（1.1）の方が近い
        #expect(sync.loopEdge(nearest: -1, as: .start) == LoopEdge(phase: .address, frames: 0))             // 範囲の外は端に収まる
        #expect(sync.loopEdge(nearest: 5, as: .end) == LoopEdge(phase: .finish, frames: 0))
    }

    @Test func edgeTimeIsClampedToTheTimeline() {
        #expect(near(sync.commonTime(of: LoopEdge(phase: .top, frames: -3), as: .start), 0.7))
        #expect(near(sync.commonTime(of: LoopEdge(phase: .address, frames: -5), as: .start), 0))
        #expect(near(sync.commonTime(of: LoopEdge(phase: .finish, frames: 5), as: .end), 1.7))
    }

    /// スイング全体（既定の範囲）は共通タイムラインの全部で、区間ではない。端を動かすと最寄りのフェーズからのコマ数になる
    @Test func allRangeCoversTheWholeTimeline() {
        #expect(sync.commonRange(of: .all) == 0...sync.commonDuration)
        #expect(LoopRange.all.segment == nil)
        var range = LoopRange.all
        range.move(.start, to: 5 * frame, in: sync)
        #expect(range.start == LoopEdge(phase: .address, frames: 5))
        range.move(.end, to: sync.commonDuration - 2 * frame, in: sync)
        #expect(range.end == LoopEdge(phase: .finish, frames: -2))
        #expect(range != .all)
    }

    @Test func segmentRangeMatchesTheSegment() {
        let range = LoopRange.segment(.downswing)
        #expect(range.segment == .downswing)
        #expect(sync.commonRange(of: range) == sync.commonRange(of: .downswing, for: .mine))
    }

    @Test func moveKeepsAtLeastOneFrameBetweenTheEdges() {
        var range = LoopRange.segment(.downswing)
        range.move(.start, to: 1.5, in: sync)                    // 終了（インパクト）を追い越そうとする
        #expect(range.start == LoopEdge(phase: .impact, frames: -1))
        #expect(range.segment == nil)
        range.move(.end, to: 0, in: sync)                        // 開始を追い越そうとする
        #expect(range.end == LoopEdge(phase: .impact, frames: 0))
        let common = sync.commonRange(of: range)
        #expect(near(common.upperBound - common.lowerBound, frame))
    }

    /// 丸めの起点（最も近いフェーズ）が反対側の端と違うと、丸めで半コマ食い込むことがある。1 コマ退いて 1 コマ以上離す
    @Test func moveBacksOffAFrameWhenRoundingIntrudes() {
        var config = mine
        config.phases.impact = 1.6183   // トップから 9.55 コマ（コマの格子がトップとずれる）
        let sync = SyncEngine(mine: config, model: model, basis: .mine)
        var range = LoopRange(start: LoopEdge(phase: .top, frames: 0), end: LoopEdge(phase: .impact, frames: -4))
        range.move(.start, to: 1.5, in: sync)
        #expect(range.start == LoopEdge(phase: .top, frames: 4))   // 丸めると 5 コマ（半コマ食い込む）なので 4 に退く
        #expect(sync.commonTime(of: range.end, as: .end) - sync.commonTime(of: range.start, as: .start) >= frame - 1e-9)
    }

    @Test func edgesFollowThePhasesWhenTheReferenceChanges() {
        let range = LoopRange(start: LoopEdge(phase: .top, frames: -3), end: LoopEdge(phase: .impact, frames: 6))
        let byMine = SyncEngine(mine: mine, model: model, basis: .mine)
        #expect(near(byMine.commonTime(of: range.start, as: .start), 0.8 - 3.0 / 30))
        let byModel = SyncEngine(mine: mine, model: model, basis: .model)
        #expect(near(byModel.commonTime(of: range.start, as: .start), 0.8 - 3.0 / 240))    // お手本の 3 コマ（1/240 秒）
        #expect(near(byModel.commonTime(of: range.end, as: .end), 1.05 + 6.0 / 240))
    }

    /// 同期しないときの区間は両方のその区間を含む範囲（開始の端は早い方、終了の端は遅い方のフェーズから数える）
    @Test func freeRunSegmentCoversBothSides() {
        var free = SyncEngine(mine: mine, model: model, basis: .free, anchor: .impact)
        // インパクトで揃えると、トップは自分 0.8 / お手本 0.85、インパクトは両方 1.1（1 コマは細かい方の 1/240 秒）
        let downswing = free.commonRange(of: .segment(.downswing))
        #expect(near(downswing.lowerBound, 0.8))
        #expect(near(downswing.upperBound, 1.1))
        #expect(free.loopEdge(nearest: 0.85, as: .start) == LoopEdge(phase: .top, frames: 12))   // 早い方のトップから 12 コマ
        #expect(free.loopEdge(nearest: 0.85, as: .end) == LoopEdge(phase: .top, frames: 0))     // 遅い方のトップそのもの
        free.anchor = .address
        // アドレスで揃えると、インパクトは自分 1.1 / お手本 1.05
        #expect(near(free.commonRange(of: .segment(.downswing)).upperBound, 1.1))
        #expect(near(free.commonRange(of: .segment(.follow)).lowerBound, 1.05))
    }

    @Test func labelReadsFramesFromThePhase() {
        #expect(LoopEdge(phase: .top, frames: 0).label == "トップ")
        #expect(LoopEdge(phase: .top, frames: -3).label == "トップ −3 コマ")
        #expect(LoopEdge(phase: .impact, frames: 6).label == "インパクト +6 コマ")
    }
}
