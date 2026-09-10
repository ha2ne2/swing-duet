import Foundation
import CoreGraphics

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

    /// 解析が終わるまでの仮の設定（動画のファイル名だけが分かっている状態）
    static func placeholder(fileName: String) -> VideoConfig {
        VideoConfig(fileName: fileName, duration: 0, frameRate: 0, phases: .fallback(duration: 0))
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
