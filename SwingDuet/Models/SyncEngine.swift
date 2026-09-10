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
    var reference: VideoSide
    /// コマ送りの 1 ステップ（基準側動画の 1 フレーム相当）
    var referenceFrameDuration: Double

    private static let eps = 1e-3

    private func phases(for side: VideoSide) -> PhaseSet {
        side == .mine ? minePhases : modelPhases
    }

    private var refPhases: PhaseSet { phases(for: reference) }

    /// 共通タイムラインの長さ（秒）
    var commonDuration: Double { max(refPhases.swingDuration, Self.eps) }

    /// 共通タイムライン上のフェーズの位置（基準側のアドレスが 0）
    func commonTime(of phase: SwingPhase) -> Double {
        min(max(refPhases.time(of: phase) - refPhases.address, 0), commonDuration)
    }

    /// 共通タイムライン上の区間の範囲（空にならないよう最低 eps の幅を持つ）
    func commonRange(of segment: SwingSegment) -> ClosedRange<Double> {
        let lower = commonTime(of: segment.start)
        return lower...max(commonTime(of: segment.end), lower + Self.eps)
    }

    func segment(at time: Double) -> SwingSegment {
        if time < commonTime(of: .top) { return .backswing }
        if time < commonTime(of: .impact) { return .downswing }
        return .follow
    }

    /// 共通タイムライン上の時刻を、指定した動画の再生時刻へ写像する
    func videoTime(at commonTime: Double, for side: VideoSide) -> Double {
        let t = min(max(commonTime, 0), commonDuration)
        let segment = segment(at: t)
        let range = commonRange(of: segment)
        let fraction = min(max((t - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
        let p = phases(for: side)
        return p.time(of: segment.start) + fraction * p.duration(of: segment)
    }

    /// 区間内での再生速度倍率（基準側は常に1.0）
    func rateMultiplier(for side: VideoSide, in segment: SwingSegment) -> Double {
        let refDuration = refPhases.duration(of: segment)
        guard refDuration > Self.eps else { return 1 }
        return max(phases(for: side).duration(of: segment) / refDuration, 0.001)
    }
}

extension SyncEngine {
    init(mine: VideoConfig, model: VideoConfig, reference: VideoSide) {
        self.init(
            minePhases: mine.phases,
            modelPhases: model.phases,
            reference: reference,
            referenceFrameDuration: (reference == .mine ? mine : model).frameDuration)
    }
}
