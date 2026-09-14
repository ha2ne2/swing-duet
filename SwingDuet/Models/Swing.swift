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
        guard duration.isFinite, duration > 0, t.isFinite else { return }
        let minGap = min(0.02, duration / 3)
        let lower: Double
        let upper: Double
        switch phase {
        case .address: (lower, upper) = (0, top - minGap)
        case .top: (lower, upper) = (address + minGap, impact - minGap)
        case .impact: (lower, upper) = (top + minGap, finish - minGap)
        case .finish: (lower, upper) = (impact + minGap, duration)
        }
        // 極端に短い区間では最小間隔を取れない。隣を追い越す値を作らず、現在のフェーズを保つ
        guard lower <= upper else { return }
        let value = min(max(t, lower), upper)
        switch phase {
        case .address: address = value
        case .top: top = value
        case .impact: impact = value
        case .finish: finish = value
        }
    }

    /// 検出結果の整合性を強制する（順序・範囲）。隣のフェーズとの間は 0.05 秒空け、短い動画では長さの 1/3 まで縮める
    mutating func sanitize(duration: Double) {
        let end = duration.isFinite ? max(duration, 0) : 0
        let minGap = min(0.05, end / 3)
        address = min(max(address, 0), max(0, end - 3 * minGap))
        top = min(max(top, address + minGap), max(0, end - 2 * minGap))
        impact = min(max(impact, top + minGap), max(0, end - minGap))
        finish = min(max(finish, impact + minGap), end)
    }

    /// 検出失敗時のフォールバック（動画長に対する割合で置く）。短い動画も実際の長さに収める（長さ 0 の仮設定では全フェーズが 0）
    static func fallback(duration: Double) -> PhaseSet {
        let d = duration.isFinite ? max(duration, 0) : 0
        return PhaseSet(address: 0.15 * d, top: 0.45 * d, impact: 0.55 * d, finish: 0.85 * d)
    }
}
