import Foundation

/// ループ範囲の端。フェーズからのコマ数（`SyncEngine.frameStep`）で持つので、フェーズ調整や同期のとり方の切り替えで
/// 共通タイムラインが伸縮しても端がフェーズに付いてくる（設計は docs/design/260912_0252-loop-trim-handles.md）
struct LoopEdge: Hashable, Codable {
    var phase: SwingPhase
    /// フェーズからのコマ数。負なら手前
    var frames: Int

    /// 表示の文言（ループのメニューの行と VoiceOver の値。「トップ」「トップ −3 コマ」）
    var label: String {
        if frames == 0 { return phase.label }
        return "\(phase.label) \(frames > 0 ? "+" : "−")\(abs(frames)) コマ"
    }
}

/// ループ範囲（開始と終了の端）。スイング全体や区間（ダウンスイングのみ等）は両端のフェーズにコマ数 0 を置いた特殊形
struct LoopRange: Hashable, Codable {
    enum Bound: CaseIterable {
        case start
        case end
    }

    var start: LoopEdge
    var end: LoopEdge

    /// スイング全体（アドレス〜フィニッシュ。既定のループ範囲）
    static let all = LoopRange(start: LoopEdge(phase: .address, frames: 0), end: LoopEdge(phase: .finish, frames: 0))

    static func segment(_ segment: SwingSegment) -> LoopRange {
        LoopRange(start: LoopEdge(phase: segment.start, frames: 0), end: LoopEdge(phase: segment.end, frames: 0))
    }

    /// ちょうど 1 区間（両端がフェーズでコマ数 0）ならその区間
    var segment: SwingSegment? {
        SwingSegment.allCases.first { Self.segment($0) == self }
    }

    subscript(bound: Bound) -> LoopEdge {
        get { bound == .start ? start : end }
        set {
            if bound == .start { start = newValue } else { end = newValue }
        }
    }

    /// 端を共通タイムライン上の time へ動かす。最も近いフェーズから整数コマの位置に丸め、反対側の端とは 1 コマ以上離す
    mutating func move(_ bound: Bound, to time: Double, in sync: SyncEngine) {
        let frame = sync.frameStep
        // 開始は終了の 1 コマ手前まで、終了は開始の 1 コマ後から
        let otherBound: Bound = bound == .start ? .end : .start
        let other = sync.commonTime(of: self[otherBound], as: otherBound)
        let limit = bound == .start ? other - frame : other + frame
        var edge = sync.loopEdge(nearest: bound == .start ? min(time, limit) : max(time, limit), as: bound)
        // 丸めの起点（最も近いフェーズ）が反対側の端と違うと、丸めで半コマまで食い込むことがある。そのときは 1 コマ退く
        let gap = bound == .start ? other - sync.commonTime(of: edge, as: bound) : sync.commonTime(of: edge, as: bound) - other
        if gap < frame - 1e-9 { edge.frames += bound == .start ? -1 : 1 }
        self[bound] = edge
    }
}

extension SyncEngine {
    /// 端の位置（共通タイムライン上の秒。0〜commonDuration に収める）。
    /// 同期しないときはフェーズの位置が側ごとに違うので、開始の端は早い方、終了の端は遅い方のフェーズから数える
    /// （「ダウンスイングのみ」は両方のダウンスイングを含む範囲になる。同期しているときは両側で同じ位置）
    func commonTime(of edge: LoopEdge, as bound: LoopRange.Bound) -> Double {
        min(max(commonTime(of: edge.phase, as: bound) + Double(edge.frames) * frameStep, 0), commonDuration)
    }

    /// time に最も近いフェーズから整数コマの位置にある端
    func loopEdge(nearest time: Double, as bound: LoopRange.Bound) -> LoopEdge {
        let t = min(max(time, 0), commonDuration)
        let phase = SwingPhase.allCases.min { abs(commonTime(of: $0, as: bound) - t) < abs(commonTime(of: $1, as: bound) - t) } ?? .address
        let frames = Int(((t - commonTime(of: phase, as: bound)) / frameStep).rounded())
        return LoopEdge(phase: phase, frames: frames)
    }

    /// ループ範囲の共通タイムライン上の範囲（終了は開始の 1 コマ以上後）
    func commonRange(of loop: LoopRange) -> ClosedRange<Double> {
        let lower = commonTime(of: loop.start, as: .start)
        return lower...max(commonTime(of: loop.end, as: .end), lower + frameStep)
    }

    /// 端の起点になるフェーズの位置（開始の端は早い方、終了の端は遅い方）
    private func commonTime(of phase: SwingPhase, as bound: LoopRange.Bound) -> Double {
        bound == .start ? firstCommonTime(of: phase) : lastCommonTime(of: phase)
    }
}
