import Foundation
import CoreGraphics

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

/// 1本の動画に対するフェーズ時刻（動画内の秒）
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

/// 動画の側（左ペインの自分 / 右ペインのお手本）。同期の基準側の指定にも使う
enum VideoSide: String, Codable, CaseIterable, Identifiable {
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

/// 1 本の動画の設定（動画の情報・自動検出の結果・フェーズ・表示変換）
struct VideoConfig: Codable, Equatable {
    var fileName: String
    var duration: Double
    var frameRate: Double
    /// 表示される映像の縦横比（幅 ÷ 高さ。回転メタデータ適用後）。0 なら不明
    var videoAspect: Double = 0
    /// 自動検出で採用したスイングの間に人物が写っていた範囲（正規化座標・左下原点）。初期表示はここが収まるように拡大する。無ければ等倍
    var focusRect: CGRect? = nil
    /// 拡大率と位置（pt）。自動フィットからの相対値で、1 と 0 のとき自動フィットどおり
    var scale: Double = 1.0
    var offsetX: Double = 0
    var offsetY: Double = 0
    var phases: PhaseSet
    var lowConfidence: Bool = false
    /// 自動検出で見つかったスイング候補（時系列順）。素振りなど複数のスイングが写る動画で、フェーズ調整画面から選び直せる
    var candidates: [PhaseSet] = []

    /// 1 フレームの長さ（秒）。コマ送りの単位。フレームレートが取れていなければ 30fps とみなす
    var frameDuration: Double {
        frameRate > 1 ? 1.0 / frameRate : 1.0 / 30.0
    }
}

extension VideoConfig {
    private enum CodingKeys: String, CodingKey {
        case fileName, duration, frameRate, videoAspect, focusRect, scale, offsetX, offsetY, phases, lowConfidence, candidates
    }

    /// 後から追加したキー（candidates / videoAspect / focusRect）が無い保存データも読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        duration = try c.decode(Double.self, forKey: .duration)
        frameRate = try c.decode(Double.self, forKey: .frameRate)
        videoAspect = try c.decodeIfPresent(Double.self, forKey: .videoAspect) ?? 0
        focusRect = try c.decodeIfPresent(CGRect.self, forKey: .focusRect)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        phases = try c.decode(PhaseSet.self, forKey: .phases)
        lowConfidence = try c.decodeIfPresent(Bool.self, forKey: .lowConfidence) ?? false
        candidates = try c.decodeIfPresent([PhaseSet].self, forKey: .candidates) ?? []
    }
}

/// 登録済みのお手本動画。名前を付けて保存し、ピッカーで選ぶだけで使える（解析結果ごと持つので再解析しない）
struct ModelVideo: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    /// 解析結果を含む動画設定。拡大率と位置は解析直後の初期値（自動フィットどおり）のまま。比較ごとの位置合わせはプロジェクト側が持つ
    var config: VideoConfig
}

/// 比較ペア = プロジェクト
struct ComparisonProject: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var mine: VideoConfig
    var model: VideoConfig
    var reference: VideoSide = .model
    /// 右ペインに入れた登録済みお手本との紐付け。お手本のフェーズ修正を登録元へ反映するのに使う。
    /// 動画ファイルは登録側と共有する。登録を消しても比較は壊れない（ファイルは比較から参照されている限り残り、紐付けが外れるだけ）
    var modelID: UUID? = nil

    func config(for side: VideoSide) -> VideoConfig {
        side == .mine ? mine : model
    }
}

extension Date {
    /// 「9/6 20:15」のような短い表記。比較やお手本の既定の名前に使う
    var compactLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: self)
    }
}
