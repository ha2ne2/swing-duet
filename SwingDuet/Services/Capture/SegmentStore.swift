import Foundation

/// 閉じた区切りファイルを保持し、使用中のショット・保持期間・全体保存の要否から削除を判断する。
/// 撮影停止中の区切りは全体保存にも必要なので、呼び手は保存完了まで prune を呼ばない。
struct SegmentStore {
    /// 決まったショットが来る余地（秒）。切り出す範囲の後ろの余白 ＋ 判定を待つ時間 ＋ 余白
    static let retention = ShotSplitter.leadOut + LiveShotJudge.waitAfterFinish + 2

    private(set) var segments: [SegmentWriter.Segment] = []

    var isEmpty: Bool { segments.isEmpty }

    /// 時刻の順（全体の動画をつなぐ順）
    var ordered: [SegmentWriter.Segment] { segments.sorted { $0.start < $1.start } }

    mutating func append(_ segment: SegmentWriter.Segment) {
        segments.append(segment)
    }

    /// その時刻（セッション秒）を含むファイル
    func segment(containing time: Double) -> SegmentWriter.Segment? {
        segments.first { $0.contains(time) }
    }

    /// 要らなくなったファイルを消す。
    /// - waitingFor: まだ切り出していない球のインパクト（そのファイルは残す）
    /// - keepsAll: 全体の動画を残す設定（止めて 1 本につなぐまで 1 つも消さない）
    mutating func prune(now: Double, waitingFor impacts: [Double], keepsAll: Bool) {
        guard !keepsAll else { return }
        for segment in segments {
            guard !impacts.contains(where: { segment.contains($0) }), segment.end + Self.retention < now else { continue }
            try? FileManager.default.removeItem(at: segment.url)
            segments.removeAll { $0.id == segment.id }
        }
    }

    /// 全部消す（止めて、全体の動画も片付いた後）
    mutating func removeAll() {
        for segment in segments {
            try? FileManager.default.removeItem(at: segment.url)
        }
        segments = []
    }
}
