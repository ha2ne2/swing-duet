import Foundation

/// 同期のとり方（操作パネルの「自分基準 / お手本基準 / 同期しない」。アプリ全体で 1 つ、`Library` に保存する）
enum SyncBasis: String, Codable, CaseIterable, Identifiable {
    /// 自分の 4 フェーズに、お手本を区間ごとに伸縮して合わせる
    case mine
    /// お手本の 4 フェーズに、自分を区間ごとに伸縮して合わせる
    case model
    /// 同期しない：両方を等速（それぞれの速さで戻した実速）で流し、選んだフェーズ 1 つだけを揃える。テンポと速さの違いをそのまま見る
    case free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mine: return "自分基準"
        case .model: return "お手本基準"
        case .free: return "同期しない"
        }
    }

    /// 基準側（同期しないときは nil）
    var reference: VideoSide? {
        switch self {
        case .mine: return .mine
        case .model: return .model
        case .free: return nil
        }
    }
}

/// 共通時刻（実秒）と各動画の時刻・倍率を対応付ける。
/// 基準側があるときはそのスイング区間を実秒に戻し、相手をフェーズ間ごとに伸縮する。
/// 同期しないときは各動画を実速で流し、anchor の瞬間だけを揃える。
/// 写像の詳細は docs/ARCHITECTURE.md §3。
struct SyncEngine: Equatable {
    /// 同期に使う 1 本の動画の情報と、その動画の中での実秒への換算
    struct Timing: Equatable {
        var phases: PhaseSet
        /// 速さ（動画秒 ÷ 実秒。`VideoConfig.effectiveSlowFactor`）
        var slowFactor: Double
        /// 1 フレームの長さ（動画秒）
        var frameDuration: Double
        /// 動画の長さ（動画秒）。同期しないときは共通タイムラインがスイング区間の外に及ぶので、動画の端で止めるのに使う
        var duration: Double

        /// 1 フレームの長さ（実秒）
        var realFrameDuration: Double { frameDuration / slowFactor }

        /// origin のフェーズから phase までの実秒（手前なら負）
        func realOffset(of phase: SwingPhase, from origin: SwingPhase) -> Double {
            (phases.time(of: phase) - phases.time(of: origin)) / slowFactor
        }
    }

    var mine: Timing
    var model: Timing
    var basis: SyncBasis
    /// 同期しないときに揃えるフェーズ（基準があるときは使わない）。既定はインパクト
    var anchor: SwingPhase = .impact

    /// 幅 0 の区間を避けるための最小の幅（実秒）
    private static let eps = 1e-3
    /// 再生速度倍率の下限。0 を返すと映像が止まってしまうので、区間長が 0 に近くても僅かに進める
    private static let minMultiplier = 0.001

    func timing(for side: VideoSide) -> Timing {
        side == .mine ? mine : model
    }

    // MARK: - 共通タイムライン

    /// 共通タイムラインの長さ（実秒）
    var commonDuration: Double {
        let end: Double
        if let reference = basis.reference {
            end = timing(for: reference).realOffset(of: .finish, from: .address)
        } else {
            end = anchorCommonTime + max(mine.realOffset(of: .finish, from: anchor), model.realOffset(of: .finish, from: anchor))
        }
        return max(end, Self.eps)
    }

    /// 共通タイムライン上のフェーズの位置。同期しているときは両側で同じ（基準側のアドレスが 0）、同期しないときは側ごとに違う
    func commonTime(of phase: SwingPhase, for side: VideoSide) -> Double {
        let time: Double
        if let reference = basis.reference {
            time = timing(for: reference).realOffset(of: phase, from: .address)
        } else {
            time = anchorCommonTime + timing(for: side).realOffset(of: phase, from: anchor)
        }
        return min(max(time, 0), commonDuration)
    }

    /// 両側のうち早い方のフェーズの位置（同期しているときは `commonTime(of:for:)` と同じ）
    func firstCommonTime(of phase: SwingPhase) -> Double {
        min(commonTime(of: phase, for: .mine), commonTime(of: phase, for: .model))
    }

    /// 両側のうち遅い方のフェーズの位置
    func lastCommonTime(of phase: SwingPhase) -> Double {
        max(commonTime(of: phase, for: .mine), commonTime(of: phase, for: .model))
    }

    /// 共通タイムライン上の、その側の区間の範囲（空にならないよう最低 eps の幅を持つ）
    func commonRange(of segment: SwingSegment, for side: VideoSide) -> ClosedRange<Double> {
        let lower = commonTime(of: segment.start, for: side)
        return lower...max(commonTime(of: segment.end, for: side), lower + Self.eps)
    }

    /// コマ送りの 1 ステップ（共通タイムライン上の実秒）。基準側動画の 1 フレーム。
    /// 同期しないときは細かい方の 1 フレーム（どちらの動画のコマも飛ばさない）
    var frameStep: Double {
        if let reference = basis.reference { return timing(for: reference).realFrameDuration }
        return min(mine.realFrameDuration, model.realFrameDuration)
    }

    // MARK: - 動画時刻への写像

    /// 共通タイムライン上の時刻を、指定した動画の再生時刻へ写像する
    func videoTime(at commonTime: Double, for side: VideoSide) -> Double {
        let t = min(max(commonTime, 0), commonDuration)
        let timing = timing(for: side)
        guard let reference = basis.reference else {
            return min(max(freeVideoTime(at: t, for: side), 0), timing.duration)
        }
        let segment = segment(at: t, reference: reference)
        let range = commonRange(of: segment, for: reference)
        let fraction = min(max((t - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
        return timing.phases.time(of: segment.start) + fraction * timing.phases.duration(of: segment)
    }

    /// その時刻での再生速度倍率（動画秒 ÷ 実秒）。
    /// 同期しているときは区間ごとに、その側の区間長（動画秒）÷ 共通タイムライン上の区間長（実秒）：
    /// 基準側は常にその速さ、非基準側は区間長の比に速さが含まれる。
    /// 同期しないときは常にその側の速さ。動画の端の外（`videoTime` が端で止まる範囲）では 0 で、端の絵のまま待つ
    func rateMultiplier(for side: VideoSide, at commonTime: Double) -> Double {
        let timing = timing(for: side)
        guard let reference = basis.reference else {
            let raw = freeVideoTime(at: min(max(commonTime, 0), commonDuration), for: side)
            return (0...timing.duration).contains(raw) ? timing.slowFactor : 0
        }
        let segment = segment(at: commonTime, reference: reference)
        let range = commonRange(of: segment, for: reference)
        let common = range.upperBound - range.lowerBound
        // 潰れた区間（フェーズが重なっている動画）は、比を取ると何百倍にもなって映像が飛ぶ。実速で流す
        guard common > Self.eps else { return 1 }
        return max(timing.phases.duration(of: segment) / common, Self.minMultiplier)
    }

    // MARK: - 同期しているとき

    /// 基準側のフェーズで区切った区間
    private func segment(at time: Double, reference: VideoSide) -> SwingSegment {
        if time < commonTime(of: .top, for: reference) { return .backswing }
        if time < commonTime(of: .impact, for: reference) { return .downswing }
        return .follow
    }

    // MARK: - 同期しないとき

    /// 揃える点（`anchor`）の共通タイムライン上の位置。早い方のアドレスが 0 に来るように置く
    private var anchorCommonTime: Double {
        -min(mine.realOffset(of: .address, from: anchor), model.realOffset(of: .address, from: anchor))
    }

    /// 再生時刻（動画秒）。動画の端で止める前の値
    private func freeVideoTime(at commonTime: Double, for side: VideoSide) -> Double {
        let t = timing(for: side)
        return t.phases.time(of: anchor) + (commonTime - anchorCommonTime) * t.slowFactor
    }
}

extension SyncEngine.Timing {
    init(_ config: VideoConfig) {
        self.init(
            phases: config.phases,
            slowFactor: config.effectiveSlowFactor > 0 ? config.effectiveSlowFactor : 1,
            frameDuration: config.frameDuration,
            duration: config.duration)
    }
}

extension SyncEngine {
    init(mine: VideoConfig, model: VideoConfig, basis: SyncBasis, anchor: SwingPhase = .impact) {
        self.init(mine: Timing(mine), model: Timing(model), basis: basis, anchor: anchor)
    }
}
