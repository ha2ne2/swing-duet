import Foundation

/// 撮影候補の登録・切り出し・本番判定を待ち合わせ、画面に出すショットを管理する。
/// 切り出しと判定はどちらが先でもよい。画面から消された仕事も完了まで所有し、停止時に待ち切る。
@MainActor
final class ShotPipeline {

    /// 区切りファイルから範囲を切り出して一時ファイルにするもの（本番はパススルー書き出し、テストは偽物）
    @MainActor
    protocol Exporting {
        func exportSegment(of url: URL, range: ClosedRange<Double>) async throws -> URL
    }

    /// 切り出した球の置き場（本番は `ClipStore`）。
    /// 写真ライブラリに触るのは `promoteCapturedShot` だけなので、テストはそこだけ差し替える
    @MainActor
    protocol Storing {
        func keepCapturedShot(at url: URL, shotAt: Date, provisional: SwingAnalysisResult) throws -> Clip
        func promoteCapturedShot(_ id: UUID) async
        func discardCapturedShot(_ id: UUID)
        func delete(_ ids: Set<UUID>)
    }

    /// 帯に出す 1 球（切り出しが終わるまで `clipID` は nil）
    struct Item: Identifiable, Equatable {
        let id: UUID
        var clipID: UUID?
    }

    /// 帯に残っている 1 球の処理状態
    private struct Entry {
        let id = UUID()
        let live: LiveShot
        var clipID: UUID?
        /// 本番（true）か素振り（false）か。判定がまだなら nil
        var isShot: Bool?
        var settlementStarted = false

        var impact: Double { live.shot.swing.phases.impact }
    }

    /// 帯に出す分。`work` から作る唯一の出口
    var items: [Item] { work.map { Item(id: $0.id, clipID: $0.clipID) } }
    /// 帯が変わった（`CaptureController` が `@Published` に写して画面に配る）
    var onItemsChanged: (([Item]) -> Void)?
    /// 切り出せなかった（呼び手が帯を出す）
    var onCutFailed: (() -> Void)?

    private var work: [Entry] = [] {
        didSet {
            let previous = oldValue.map { Item(id: $0.id, clipID: $0.clipID) }
            guard previous != items else { return }
            onItemsChanged?(items)
        }
    }

    // 帯から消した項目の仕事も完了まで所有する。入力ファイルの保持と停止時の待ち合わせは、この列で決める
    private struct Cut {
        let impact: Double
        let task: Task<Void, Never>
    }
    private var cuts: [UUID: Cut] = [:]
    private var settlements: [UUID: Task<Void, Never>] = [:]

    private let store: Storing
    private let exporter: Exporting
    private let log: CaptureLog?
    /// 録画を始めた日時（切り出したクリップの撮影日時に使う）
    private let startedAt: Date

    init(store: Storing, exporter: Exporting, startedAt: Date, log: CaptureLog?) {
        self.store = store
        self.exporter = exporter
        self.startedAt = startedAt
        self.log = log
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// まだ切り出していない球のインパクト（その区切りファイルはまだ消せない）
    var impactsWaitingForCut: [Double] {
        work.filter { $0.clipID == nil && cuts[$0.id] == nil }.map(\.impact) + cuts.values.map(\.impact)
    }

    // MARK: - 出来事

    /// 見つかった候補を帯に出す（合図と「＋1」は呼び手が出す）
    func register(_ live: LiveShot) {
        work.append(Entry(live: live))
        log?.line(String(format: "registered range=[%.2f, %.2f] impact=%.2f",
                         live.shot.range.lowerBound, live.shot.range.upperBound, live.shot.swing.phases.impact))
    }

    /// インパクトを含む区切りファイルが閉じている球を切り出す
    func startCuts(from segments: SegmentStore) {
        for pending in work where pending.clipID == nil && cuts[pending.id] == nil {
            guard let segment = segments.segment(containing: pending.impact) else { continue }
            cuts[pending.id] = Cut(impact: pending.impact, task: Task {
                await self.cut(pending.id, live: pending.live, from: segment)
                self.cuts[pending.id] = nil
            })
        }
    }

    /// 本番か素振りかの判定を反映する
    func apply(_ verdicts: [LiveShotJudge.Verdict]) {
        for verdict in verdicts {
            guard let index = work.firstIndex(where: { LiveShotJudge.isSameSwing($0.live.shot.swing, verdict.candidate) }) else {
                log?.line(String(format: "verdict without shot impact=%.2f", verdict.candidate.phases.impact))
                continue
            }
            work[index].isShot = verdict.shot != nil
            log?.line(String(format: "verdict %@ impact=%.2f", verdict.shot == nil ? "practice" : "shot", verdict.candidate.phases.impact))
            settleIfReady(work[index].id)
        }
    }

    /// 帯から消す（誤検出をその場で捨てる）。クリップができていれば一緒に消す（「元に戻す」に残る）
    func remove(_ id: UUID) {
        if let clipID = work.first(where: { $0.id == id })?.clipID {
            store.delete([clipID])
        }
        work.removeAll { $0.id == id }
    }

    /// 止めるとき：残りの切り出しと判定の反映を待ち切り、クリップにならなかった分を帯から落とす。
    /// 以後 `items` は保存できた球だけ
    func finish() async {
        while let cut = cuts.values.first { await cut.task.value }
        for pending in work { settleIfReady(pending.id) }
        while let task = settlements.values.first { await task.value }
        work.removeAll { $0.clipID == nil }
    }

    // MARK: - 中身

    /// 区切りファイルから切り出し、アプリ内のファイルの仮のクリップにする
    private func cut(_ id: UUID, live: LiveShot, from segment: SegmentWriter.Segment) async {
        guard let local = segment.localRange(of: live.shot.range) else {
            log?.line(String(format: "shot dropped: 範囲が区切りファイルの外 impact=%.2f", live.shot.swing.phases.impact))
            remove(id)
            return
        }
        do {
            let url = try await exporter.exportSegment(of: segment.url, range: local)
            // 削除済みならクリップを新しく作らない。書き出し失敗・取り込み失敗の一時ファイルも残さない
            defer { try? FileManager.default.removeItem(at: url) }
            guard work.contains(where: { $0.id == id }) else { return }
            let shotAt = startedAt.addingTimeInterval(segment.start + local.lowerBound)
            // 区切りの端で範囲が切り詰められていれば、仮の解析もその分にずらす
            let offset = segment.start + local.lowerBound - live.shot.range.lowerBound
            let provisional = live.provisional.sliced(to: offset...(offset + local.upperBound - local.lowerBound))
            let clip = try store.keepCapturedShot(at: url, shotAt: shotAt, provisional: provisional)
            log?.line(String(format: "shot kept range=[%.2f, %.2f] clip=%@",
                             live.shot.range.lowerBound, live.shot.range.upperBound, clip.id.uuidString))
            guard let index = work.firstIndex(where: { $0.id == id }) else {   // 保存先の処理中に項目が取り除かれた場合も参照を残さない
                store.discardCapturedShot(clip.id)
                return
            }
            work[index].clipID = clip.id
            settleIfReady(id)
        } catch {
            log?.line("shot failed: \(error.localizedDescription)")
            remove(id)
            onCutFailed?()
        }
    }

    /// 切り出しと判定の両方がそろった球を片付ける：本番は写真ライブラリへ移し、素振りはクリップごと消して帯からも外す
    private func settleIfReady(_ id: UUID) {
        guard let index = work.firstIndex(where: { $0.id == id }),
              let clipID = work[index].clipID, let isShot = work[index].isShot,
              !work[index].settlementStarted else { return }
        guard isShot else {
            store.discardCapturedShot(clipID)
            work.removeAll { $0.id == id }
            return
        }
        work[index].settlementStarted = true
        settlements[id] = Task { @MainActor in
            await store.promoteCapturedShot(clipID)
            settlements[id] = nil
        }
    }
}
