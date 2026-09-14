import Testing
import Foundation
@testable import SwingDuet

/// 撮影中の 1 球の面倒（登録 → 切り出し → 判定の反映）を固定する。
/// 3 つの出来事は順序が入れ替わるので、どちらが先でも同じ結果になることを見る
@MainActor
struct ShotPipelineTests {

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShotPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 切り出しの偽物：本番はパススルー書き出しで一時ファイルを作る。ここでは中身のあるファイルを 1 つ作って返す
    private struct FakeExporter: ShotPipeline.Exporting {
        var fails = false

        func exportSegment(of url: URL, range: ClosedRange<Double>) async throws -> URL {
            if fails { throw VideoError.unreadable }
            let output = URL.temporary(extension: "mov")
            try Data("cut".utf8).write(to: output)
            return output
        }
    }

    /// 片付け先の偽物：写真ライブラリへ移すところだけ止め、ほかは本物の `ClipStore` に任せる
    /// （テストはホストアプリを持たないので、PhotoKit を呼ぶと返ってこない）
    @MainActor
    private final class TestStore: ShotPipeline.Storing {
        let clips: ClipStore
        private(set) var promoted: [UUID] = []

        init(_ clips: ClipStore) { self.clips = clips }

        func keepCapturedShot(at url: URL, shotAt: Date, provisional: SwingAnalysisResult) throws -> Clip {
            try clips.keepCapturedShot(at: url, shotAt: shotAt, provisional: provisional)
        }
        func promoteCapturedShot(_ id: UUID) async { promoted.append(id) }
        func discardCapturedShot(_ id: UUID) { clips.discardCapturedShot(id) }
        func delete(_ ids: Set<UUID>) { clips.delete(ids) }
    }

    private func makeStore() -> TestStore {
        TestStore(ClipStore(documentsURL: directory, autoAnalyze: false))
    }

    private func makePipeline(store: TestStore, fails: Bool = false) -> ShotPipeline {
        ShotPipeline(store: store, exporter: FakeExporter(fails: fails), startedAt: Date(timeIntervalSince1970: 1_700_000_000), log: nil)
    }

    /// インパクトを `impact` に置いた 1 球（切り出す範囲は前後の余白付き）
    private func liveShot(impact: Double) throws -> LiveShot {
        let candidate = SwingCandidate(
            phases: PhaseSet(address: impact - 1.0, top: impact - 0.3, impact: impact, finish: impact + 0.8),
            rise: 1.5, peakSpeed: 5, estimated: [], score: 1)
        let range = try #require(ShotSplitter.range(of: candidate))
        let provisional = SwingAnalysisResult(
            duration: range.upperBound - range.lowerBound, frameRate: 240, videoAspect: 0.5625,
            pose: PoseTrack(frames: []), candidates: [])
        return LiveShot(shot: Shot(range: range, swing: candidate), provisional: provisional)
    }

    private func segment(_ start: Double, _ end: Double) -> SegmentWriter.Segment {
        SegmentWriter.Segment(id: UUID(), url: directory.appendingPathComponent("\(UUID().uuidString).mov"),
                              start: start, end: end, droppedFrames: 0)
    }

    private func store(_ segment: SegmentWriter.Segment) -> SegmentStore {
        var segments = SegmentStore()
        segments.append(segment)
        return segments
    }

    private func verdict(_ live: LiveShot, isShot: Bool) -> LiveShotJudge.Verdict {
        LiveShotJudge.Verdict(candidate: live.shot.swing,
                              shot: isShot ? live.shot : nil,
                              decidedAt: live.shot.swing.phases.finish + 6)
    }

    // MARK: - 登録と切り出し

    @Test func aRegisteredShotIsInTheBandBeforeItIsCut() throws {
        let pipeline = makePipeline(store: makeStore())
        let live = try liveShot(impact: 10)
        pipeline.register(live)

        #expect(pipeline.items.count == 1)
        #expect(pipeline.items[0].clipID == nil)
        #expect(pipeline.impactsWaitingForCut == [10])
    }

    /// インパクトを含む区切りファイルが閉じるまで切り出さない
    @Test func cuttingWaitsForTheSegmentThatHoldsTheImpact() async throws {
        let pipeline = makePipeline(store: makeStore())
        pipeline.register(try liveShot(impact: 40))

        pipeline.startCuts(from: store(segment(0, 30)))   // インパクトが入らないファイル
        await pipeline.finish()
        #expect(pipeline.items.isEmpty)                    // 切り出せないまま止めたので帯から落ちる
    }

    @Test func cuttingFillsInTheClipAndKeepsTheBandInStep() async throws {
        let store = makeStore()
        let pipeline = makePipeline(store: store)
        pipeline.register(try liveShot(impact: 10))

        pipeline.startCuts(from: self.store(segment(0, 30)))
        await pipeline.finish()

        #expect(pipeline.items.count == 1)
        let clipID = try #require(pipeline.items[0].clipID)
        #expect(store.clips.clip(id: clipID)?.needsReanalysis == true)   // 仮のフェーズなので後で解析し直す
        #expect(pipeline.impactsWaitingForCut.isEmpty)             // もう区切りファイルは要らない
    }

    @Test func aFailedCutLeavesNothingBehind() async throws {
        let store = makeStore()
        let pipeline = makePipeline(store: store, fails: true)
        var failures = 0
        pipeline.onCutFailed = { failures += 1 }
        pipeline.register(try liveShot(impact: 10))

        pipeline.startCuts(from: self.store(segment(0, 30)))
        await pipeline.finish()

        #expect(pipeline.items.isEmpty)
        #expect(store.clips.clips.isEmpty)
        #expect(failures == 1)
    }

    // MARK: - 判定の反映（順序が入れ替わっても同じ）

    @Test func practiceIsDroppedWhenTheVerdictComesAfterTheCut() async throws {
        let store = makeStore()
        let pipeline = makePipeline(store: store)
        let live = try liveShot(impact: 10)
        pipeline.register(live)
        pipeline.startCuts(from: self.store(segment(0, 30)))
        await pipeline.finish()

        pipeline.apply([verdict(live, isShot: false)])

        #expect(pipeline.items.isEmpty)   // 素振りは帯からも消える
        #expect(store.clips.clips.isEmpty)      // クリップごと消える（「元に戻す」にも残さない）
        #expect(store.clips.lastDeleted.isEmpty)
    }

    @Test func practiceIsDroppedWhenTheVerdictComesBeforeTheCut() async throws {
        let store = makeStore()
        let pipeline = makePipeline(store: store)
        let live = try liveShot(impact: 10)
        pipeline.register(live)

        pipeline.apply([verdict(live, isShot: false)])   // 判定が先に来る
        pipeline.startCuts(from: self.store(segment(0, 30)))
        await pipeline.finish()

        #expect(pipeline.items.isEmpty)
        #expect(store.clips.clips.isEmpty)
    }

    @Test func aShotStaysInTheBandWithItsClip() async throws {
        let store = makeStore()
        let pipeline = makePipeline(store: store)
        let live = try liveShot(impact: 10)
        pipeline.register(live)
        pipeline.startCuts(from: self.store(segment(0, 30)))
        await pipeline.finish()

        pipeline.apply([verdict(live, isShot: true)])
        await pipeline.finish()

        #expect(pipeline.items.count == 1)
        #expect(store.clips.clips.count == 1)
        #expect(store.promoted.count == 1)   // 本番は写真ライブラリへ移す
    }

    /// 候補に当たらない判定（同じスイングが見つからない）は捨てるだけで、帯は変わらない
    @Test func aVerdictWithoutAMatchingShotIsIgnored() throws {
        let pipeline = makePipeline(store: makeStore())
        let live = try liveShot(impact: 10)
        pipeline.register(live)

        pipeline.apply([verdict(try liveShot(impact: 40), isShot: false)])

        #expect(pipeline.items.count == 1)
    }

    // MARK: - 帯から消す・止める

    @Test func removingFromTheBandDeletesTheClipToo() async throws {
        let store = makeStore()
        let pipeline = makePipeline(store: store)
        pipeline.register(try liveShot(impact: 10))
        pipeline.startCuts(from: self.store(segment(0, 30)))
        await pipeline.finish()

        pipeline.remove(try #require(pipeline.items.first).id)

        #expect(pipeline.items.isEmpty)
        #expect(store.clips.clips.isEmpty)
        #expect(store.clips.lastDeleted.count == 1)   // 「元に戻す」で戻せる
    }

    @Test func finishDropsShotsThatNeverBecameClips() async throws {
        let store = makeStore()
        let pipeline = makePipeline(store: store)
        pipeline.register(try liveShot(impact: 10))   // 切り出せる
        pipeline.register(try liveShot(impact: 90))   // 区切りファイルが無い

        pipeline.startCuts(from: self.store(segment(0, 30)))
        await pipeline.finish()

        #expect(pipeline.items.count == 1)
        #expect(store.clips.clips.count == 1)
    }
    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class SuspendedExporter: ShotPipeline.Exporting {
        let started = Gate()
        let release = Gate()
        let output: URL
        init(output: URL) { self.output = output }
        func exportSegment(of url: URL, range: ClosedRange<Double>) async throws -> URL {
            started.open()
            await release.wait()
            try Data("cut".utf8).write(to: output)
            return output
        }
    }

    @Test func removingAnActiveCutStillProtectsItsSegmentAndWaitsForCleanup() async throws {
        let store = makeStore()
        let exporter = SuspendedExporter(output: directory.appendingPathComponent("pending.mov"))
        let pipeline = ShotPipeline(store: store, exporter: exporter, startedAt: Date(), log: nil)
        pipeline.register(try liveShot(impact: 10))
        pipeline.startCuts(from: self.store(segment(0, 30)))
        await exporter.started.wait()
        pipeline.remove(try #require(pipeline.items.first).id)
        #expect(pipeline.items.isEmpty)
        #expect(pipeline.impactsWaitingForCut == [10])
        var finished = false
        let entered = Gate()
        let finishing = Task { entered.open(); await pipeline.finish(); finished = true }
        await entered.wait()
        await Task.yield()
        #expect(!finished)
        exporter.release.open()
        await finishing.value
        #expect(pipeline.impactsWaitingForCut.isEmpty)
        #expect(store.clips.clips.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: exporter.output.path))
    }

    @MainActor
    private final class SuspendedStore: ShotPipeline.Storing {
        let wrapped: TestStore
        let started = Gate()
        let release = Gate()
        init(_ wrapped: TestStore) { self.wrapped = wrapped }
        func keepCapturedShot(at url: URL, shotAt: Date, provisional: SwingAnalysisResult) throws -> Clip {
            try wrapped.keepCapturedShot(at: url, shotAt: shotAt, provisional: provisional)
        }
        func promoteCapturedShot(_ id: UUID) async {
            started.open()
            await release.wait()
            await wrapped.promoteCapturedShot(id)
        }
        func discardCapturedShot(_ id: UUID) { wrapped.discardCapturedShot(id) }
        func delete(_ ids: Set<UUID>) { wrapped.delete(ids) }
    }

    @Test func removingAPromotingShotDoesNotDropItsCompletionWait() async throws {
        let store = SuspendedStore(makeStore())
        let pipeline = ShotPipeline(store: store, exporter: FakeExporter(), startedAt: Date(), log: nil)
        let live = try liveShot(impact: 10)
        pipeline.register(live)
        pipeline.apply([verdict(live, isShot: true)])
        pipeline.startCuts(from: self.store(segment(0, 30)))
        await store.started.wait()
        pipeline.remove(try #require(pipeline.items.first).id)
        var finished = false
        let entered = Gate()
        let finishing = Task { entered.open(); await pipeline.finish(); finished = true }
        await entered.wait()
        await Task.yield()
        #expect(!finished)
        store.release.open()
        await finishing.value
        #expect(store.wrapped.promoted.count == 1)
    }

}
