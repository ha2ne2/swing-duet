import Foundation
import SwiftUI

/// スイングの4フェーズ（MVP）
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

/// フェーズで区切られる3区間
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

    var color: Color {
        switch self {
        case .backswing: return .blue
        case .downswing: return .orange
        case .follow: return .green
        }
    }
}

/// 1本の動画に対するフェーズ時刻（動画内の秒）
struct PhaseSet: Codable, Equatable {
    var address: Double
    var top: Double
    var impact: Double
    var finish: Double

    var backswingDuration: Double { max(top - address, 0) }
    var downswingDuration: Double { max(impact - top, 0) }
    var followDuration: Double { max(finish - impact, 0) }
    var swingDuration: Double { max(finish - address, 0) }

    /// テンポ比（バックスイング : ダウンスイング = N : 1）
    var tempoRatio: Double {
        guard downswingDuration > 0.0001 else { return 0 }
        return backswingDuration / downswingDuration
    }

    var tempoText: String {
        String(format: "%.1f : 1", tempoRatio)
    }

    func time(of phase: SwingPhase) -> Double {
        switch phase {
        case .address: return address
        case .top: return top
        case .impact: return impact
        case .finish: return finish
        }
    }

    func duration(of segment: SwingSegment) -> Double {
        switch segment {
        case .backswing: return backswingDuration
        case .downswing: return downswingDuration
        case .follow: return followDuration
        }
    }

    /// マーカードラッグ用：順序（address < top < impact < finish）を保ったまま更新する
    mutating func assign(_ phase: SwingPhase, to t: Double, duration: Double, minGap: Double = 0.02) {
        let clamped = min(max(t, 0), duration)
        switch phase {
        case .address:
            address = min(clamped, top - minGap)
            address = max(address, 0)
        case .top:
            top = min(max(clamped, address + minGap), impact - minGap)
        case .impact:
            impact = min(max(clamped, top + minGap), finish - minGap)
        case .finish:
            finish = max(clamped, impact + minGap)
            finish = min(finish, duration)
        }
    }

    /// 検出結果の整合性を強制する（順序・範囲）
    mutating func sanitize(duration: Double, minGap: Double = 0.05) {
        address = min(max(address, 0), duration)
        top = max(top, address + minGap)
        impact = max(impact, top + minGap)
        finish = max(finish, impact + minGap)
        if finish > duration {
            finish = duration
            impact = min(impact, finish - minGap)
            top = min(top, impact - minGap)
            address = min(address, top - minGap)
            address = max(address, 0)
        }
    }

    /// 検出失敗時のフォールバック（動画長の四分位ベース）
    static func fallback(duration: Double) -> PhaseSet {
        let d = max(duration, 0.4)
        return PhaseSet(address: 0.15 * d, top: 0.45 * d, impact: 0.55 * d, finish: min(0.85 * d, d))
    }
}

/// 同期の基準側
enum ReferenceSide: String, Codable, CaseIterable, Identifiable {
    case mine
    case model

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mine: return "自分"
        case .model: return "お手本"
        }
    }
}

/// 1本の動画の設定（表示変換 + フェーズ）
struct VideoConfig: Codable, Equatable {
    var fileName: String
    var duration: Double
    var frameRate: Double
    var mirrored: Bool = false
    var scale: Double = 1.0
    var offsetX: Double = 0
    var offsetY: Double = 0
    var phases: PhaseSet
    var lowConfidence: Bool = false
}

/// 比較ペア = プロジェクト
struct ComparisonProject: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var mine: VideoConfig
    var model: VideoConfig
    var reference: ReferenceSide = .model

    func config(for side: ReferenceSide) -> VideoConfig {
        side == .mine ? mine : model
    }
}
