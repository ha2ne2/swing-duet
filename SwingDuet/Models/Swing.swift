import Foundation

/// スイングの 4 フェーズ
enum SwingPhase: String, Codable, CaseIterable, Identifiable {
    case address
    case top
    case impact
    case finish

    var id: String { rawValue }

    var label: String {
        switch self {
        case .address: return "アドレス"
        case .top: return "トップ"
        case .impact: return "インパクト"
        case .finish: return "フィニッシュ"
        }
    }

    var shortLabel: String {
        switch self {
        case .address: return "A"
        case .top: return "T"
        case .impact: return "I"
        case .finish: return "F"
        }
    }
}

/// フェーズで区切られる 3 区間
enum SwingSegment: String, Codable, CaseIterable, Identifiable {
    case backswing
    case downswing
    case follow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .backswing: return "バックスイング"
        case .downswing: return "ダウンスイング"
        case .follow: return "フォロー"
        }
    }

    /// 区間の始まりのフェーズ
    var start: SwingPhase {
        switch self {
        case .backswing: return .address
        case .downswing: return .top
        case .follow: return .impact
        }
    }

    /// 区間の終わりのフェーズ
    var end: SwingPhase {
        switch self {
        case .backswing: return .top
        case .downswing: return .impact
        case .follow: return .finish
        }
    }
}

/// 1 本の動画に対するフェーズ時刻（動画内の秒）
struct PhaseSet: Codable, Equatable {
    var address: Double
    var top: Double
    var impact: Double
    var finish: Double

    func time(of phase: SwingPhase) -> Double {
        switch phase {
        case .address: return address
        case .top: return top
        case .impact: return impact
        case .finish: return finish
        }
    }

    func duration(of segment: SwingSegment) -> Double {
        max(time(of: segment.end) - time(of: segment.start), 0)
    }

    /// アドレス〜フィニッシュの長さ
    var swingDuration: Double { max(finish - address, 0) }

    /// テンポ比（バックスイング : ダウンスイング = N : 1）
    var tempoRatio: Double {
        let downswing = duration(of: .downswing)
        guard downswing > 0.0001 else { return 0 }
        return duration(of: .backswing) / downswing
    }

    var tempoText: String {
        String(format: "%.1f : 1", tempoRatio)
    }

    /// マーカードラッグ用：順序（address < top < impact < finish）を保ったまま 1 つのフェーズを動かす。
    /// 隣のフェーズとの間は最低 0.02 秒（約 1 コマ）空ける
    mutating func assign(_ phase: SwingPhase, to t: Double, duration: Double) {
        let minGap = 0.02
        let clamped = min(max(t, 0), duration)
        switch phase {
        case .address:
            address = max(min(clamped, top - minGap), 0)
        case .top:
            top = min(max(clamped, address + minGap), impact - minGap)
        case .impact:
            impact = min(max(clamped, top + minGap), finish - minGap)
        case .finish:
            finish = min(max(clamped, impact + minGap), duration)
        }
    }

    /// 検出結果の整合性を強制する（順序・範囲）。隣のフェーズとの間は最低 0.05 秒空ける
    mutating func sanitize(duration: Double) {
        let minGap = 0.05
        address = min(max(address, 0), duration)
        top = max(top, address + minGap)
        impact = max(impact, top + minGap)
        finish = max(finish, impact + minGap)
        if finish > duration {
            finish = duration
            impact = min(impact, finish - minGap)
            top = min(top, impact - minGap)
            address = max(min(address, top - minGap), 0)
        }
    }

    /// 検出失敗時のフォールバック（動画長に対する割合で置く）。極端に短い動画でもフェーズが重ならないように長さの下限を設ける
    static func fallback(duration: Double) -> PhaseSet {
        let d = max(duration, 0.4)
        return PhaseSet(address: 0.15 * d, top: 0.45 * d, impact: 0.55 * d, finish: 0.85 * d)
    }
}
