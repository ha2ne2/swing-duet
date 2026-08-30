import Foundation

/// 2本の動画を「共通タイムライン」で同期するための写像。
///
/// - 共通タイムラインは基準側（自分 / お手本）のスイング区間（アドレス〜フィニッシュ）と同じ長さ。
/// - 基準点はインパクト固定：共通タイムライン上のインパクト位置は基準側のインパクトで決まり、
///   非基準側は各区間（バックスイング / ダウンスイング / フォロー）を区間ごとに線形伸縮して
///   アドレス・トップ・インパクト・フィニッシュが必ず一致する。
struct SyncEngine: Equatable {
    var minePhases: PhaseSet
    var modelPhases: PhaseSet
    var reference: ReferenceSide
    var referenceFrameRate: Double

    private static let eps = 1e-3

    init(project: ComparisonProject) {
        self.minePhases = project.mine.phases
        self.modelPhases = project.model.phases
        self.reference = project.reference
        self.referenceFrameRate = project.config(for: project.reference).frameRate
    }

    func phases(for side: ReferenceSide) -> PhaseSet {
        side == .mine ? minePhases : modelPhases
    }

    var refPhases: PhaseSet { phases(for: reference) }

    /// 共通タイムラインの長さ（秒）
    var commonDuration: Double { max(refPhases.swingDuration, Self.eps) }

    /// 共通タイムライン上のトップ位置
    var topBoundary: Double { min(max(refPhases.top - refPhases.address, 0), commonDuration) }

    /// 共通タイムライン上のインパクト位置
    var impactBoundary: Double { min(max(refPhases.impact - refPhases.address, topBoundary), commonDuration) }

    func segment(at commonTime: Double) -> SwingSegment {
        if commonTime < topBoundary { return .backswing }
        if commonTime < impactBoundary { return .downswing }
        return .follow
    }

    func commonRange(of segment: SwingSegment) -> ClosedRange<Double> {
        switch segment {
        case .backswing:
            return 0...max(topBoundary, Self.eps)
        case .downswing:
            return topBoundary...max(impactBoundary, topBoundary + Self.eps)
        case .follow:
            return impactBoundary...max(commonDuration, impactBoundary + Self.eps)
        }
    }

    func commonTime(of phase: SwingPhase) -> Double {
        switch phase {
        case .address: return 0
        case .top: return topBoundary
        case .impact: return impactBoundary
        case .finish: return commonDuration
        }
    }

    /// 共通タイムライン上の時刻を、指定した動画の再生時刻へ写像する
    func videoTime(at commonTime: Double, for side: ReferenceSide) -> Double {
        let p = phases(for: side)
        let t = min(max(commonTime, 0), commonDuration)
        let seg = segment(at: t)
        let range = commonRange(of: seg)
        let span = max(range.upperBound - range.lowerBound, Self.eps)
        let frac = min(max((t - range.lowerBound) / span, 0), 1)
        switch seg {
        case .backswing:
            return p.address + frac * p.backswingDuration
        case .downswing:
            return p.top + frac * p.downswingDuration
        case .follow:
            return p.impact + frac * p.followDuration
        }
    }

    /// 区間内での再生速度倍率（基準側は常に1.0）
    func rateMultiplier(for side: ReferenceSide, in segment: SwingSegment) -> Double {
        let refDur = commonRange(of: segment).upperBound - commonRange(of: segment).lowerBound
        guard refDur > Self.eps else { return 1 }
        let dur = phases(for: side).duration(of: segment)
        return max(dur / refDur, 0.001)
    }

    /// コマ送りの1ステップ（基準側動画の1フレーム相当）
    var referenceFrameDuration: Double {
        referenceFrameRate > 1 ? 1.0 / referenceFrameRate : 1.0 / 30.0
    }
}
