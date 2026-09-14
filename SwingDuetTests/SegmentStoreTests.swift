import Testing
import Foundation
@testable import SwingDuet

/// 閉じた区切りファイルをいつ消すかを固定する。
/// 早く消すと切り出しや全体の動画に要るファイルが無くなり、消さないと 480 MB/分 で溜まり続ける
@MainActor
struct SegmentStoreTests {

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SegmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 中身のあるファイルを作って区切りにする（消えたかどうかを見るため）
    private func segment(_ start: Double, _ end: Double) throws -> SegmentWriter.Segment {
        let url = directory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data("segment".utf8).write(to: url)
        return SegmentWriter.Segment(id: UUID(), url: url, start: start, end: end, droppedFrames: 0)
    }

    private func exists(_ segment: SegmentWriter.Segment) -> Bool {
        FileManager.default.fileExists(atPath: segment.url.path)
    }

    @Test func theSegmentHoldingAnImpactIsFound() throws {
        var store = SegmentStore()
        let first = try segment(0, 60)
        let second = try segment(60, 120)
        store.append(first)
        store.append(second)

        #expect(store.segment(containing: 30)?.id == first.id)
        #expect(store.segment(containing: 90)?.id == second.id)
        #expect(store.segment(containing: 200) == nil)
    }

    @Test func orderedSortsByStartTime() throws {
        var store = SegmentStore()
        let second = try segment(60, 120)
        let first = try segment(0, 60)
        store.append(second)
        store.append(first)

        #expect(store.ordered.map(\.id) == [first.id, second.id])
    }

    /// まだ切り出していない球が入っているファイルは、保持期間を過ぎていても消さない
    @Test func aSegmentIsKeptWhileAShotStillNeedsIt() throws {
        var store = SegmentStore()
        let held = try segment(0, 60)
        store.append(held)

        store.prune(now: 1000, waitingFor: [30], keepsAll: false)

        #expect(exists(held))
        #expect(!store.isEmpty)
    }

    /// 決まったショットが来る余地（`retention`）を過ぎたら消す
    @Test func aSegmentIsRemovedOnlyAfterTheRetention() throws {
        var store = SegmentStore()
        let old = try segment(0, 60)
        store.append(old)

        store.prune(now: 60 + SegmentStore.retention, waitingFor: [], keepsAll: false)
        #expect(exists(old))   // ちょうどではまだ消さない

        store.prune(now: 60 + SegmentStore.retention + 0.1, waitingFor: [], keepsAll: false)
        #expect(!exists(old))
        #expect(store.isEmpty)
    }

    /// 全体の動画を残す設定の間は 1 つも消さない（止めて 1 本につなぐまで要る）
    @Test func nothingIsRemovedWhileTheWholeTakeIsKept() throws {
        var store = SegmentStore()
        let old = try segment(0, 60)
        store.append(old)

        store.prune(now: 10_000, waitingFor: [], keepsAll: true)

        #expect(exists(old))
    }

    @Test func removeAllDeletesTheFiles() throws {
        var store = SegmentStore()
        let a = try segment(0, 60)
        let b = try segment(60, 120)
        store.append(a)
        store.append(b)

        store.removeAll()

        #expect(!exists(a) && !exists(b))
        #expect(store.isEmpty)
    }

    /// 保持期間は切り出しの余白と判定の待ち時間から導く（規則を変えたら追随する）
    @Test func retentionCoversTheLeadOutAndTheJudgingWait() {
        #expect(SegmentStore.retention > ShotSplitter.leadOut + LiveShotJudge.waitAfterFinish)
    }
}
