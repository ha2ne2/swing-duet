import Foundation
import CoreGraphics

/// 1 本の動画の設定（動画の情報・自動検出の結果・フェーズ・表示変換）
struct VideoConfig: Codable, Equatable {
    var fileName: String
    var duration: Double
    var frameRate: Double
    /// ユーザーが選んだ動画の速さ（`SlowFactor`）。nil なら推定（`estimatedSlowFactor`）に従う。
    /// 再生に使う値は `effectiveSlowFactor`
    var slowFactor: Double? = nil
    /// 表示される映像の縦横比（幅 ÷ 高さ。回転メタデータ適用後）。0 なら不明
    var videoAspect: Double = 0
    /// 自動検出で採用したスイングの間に人物が写っていた範囲（正規化座標・左下原点）。初期表示はここが収まるように拡大する。無ければ等倍
    var focusRect: CGRect? = nil
    var transform: PaneTransform = .identity
    var phases: PhaseSet
    var lowConfidence: Bool = false
    /// 自動検出で見つかったスイング候補（時系列順）。素振りなど複数のスイングが写る動画で、フェーズ調整画面から選び直せる
    var candidates: [PhaseSet] = []
    /// 部位（手・頭・左右の肩・左右の股関節）の軌跡（採用スイングの周り。比較画面で動画に重ねる）。
    /// 検出に失敗した動画と古い保存データでは無し（`JointTrails.isCurrent` が false なら比較画面が作り直す）
    var jointTrails: JointTrails? = nil

    /// フレームレートが取れていない動画の 1 コマの長さ（秒）。30fps とみなす
    static let fallbackFrameDuration = 1.0 / 30.0

    /// 1 フレームの長さ（秒）。コマ送りの単位
    var frameDuration: Double {
        frameRate > 1 ? 1.0 / frameRate : Self.fallbackFrameDuration
    }

    /// いまのフェーズから推定した動画の速さ（`estimatedSlowFactor(for:)`）
    var estimatedSlowFactor: Double {
        estimatedSlowFactor(for: phases)
    }

    /// フェーズから推定した動画の速さ。フェーズが検出失敗時の仮の値のままなら手掛かりが無いので実速。
    /// フェーズの純関数なので、手で直せば推定も追従する（検出に失敗したスーパースロー動画でも、フェーズを置けば倍率が出る）
    func estimatedSlowFactor(for phases: PhaseSet) -> Double {
        phases == .fallback(duration: duration) ? 1 : SlowFactor.estimate(downswingDuration: phases.duration(of: .downswing))
    }

    /// 再生に使う動画の速さ（ユーザーの選択があればそれ、無ければ推定）
    var effectiveSlowFactor: Double {
        slowFactor ?? estimatedSlowFactor
    }

    /// 解析が終わるまでの仮の設定（動画のファイル名だけが分かっている状態）
    static func placeholder(fileName: String) -> VideoConfig {
        VideoConfig(fileName: fileName, duration: 0, frameRate: 0, phases: .fallback(duration: 0))
    }
}

extension VideoConfig {
    private enum CodingKeys: String, CodingKey {
        case fileName, duration, frameRate, slowFactor, videoAspect, focusRect, phases, lowConfidence, candidates, jointTrails
    }

    /// 後から追加したキー（candidates / videoAspect / focusRect / slowFactor / jointTrails）が無い保存データも読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        duration = try c.decode(Double.self, forKey: .duration)
        frameRate = try c.decode(Double.self, forKey: .frameRate)
        slowFactor = try c.decodeIfPresent(Double.self, forKey: .slowFactor)
        videoAspect = try c.decodeIfPresent(Double.self, forKey: .videoAspect) ?? 0
        focusRect = try c.decodeIfPresent(CGRect.self, forKey: .focusRect)
        transform = try PaneTransform(from: decoder)
        phases = try c.decode(PhaseSet.self, forKey: .phases)
        lowConfidence = try c.decodeIfPresent(Bool.self, forKey: .lowConfidence) ?? false
        candidates = try c.decodeIfPresent([PhaseSet].self, forKey: .candidates) ?? []
        jointTrails = try c.decodeIfPresent(JointTrails.self, forKey: .jointTrails)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(duration, forKey: .duration)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encodeIfPresent(slowFactor, forKey: .slowFactor)
        try c.encode(videoAspect, forKey: .videoAspect)
        try c.encodeIfPresent(focusRect, forKey: .focusRect)
        try c.encode(phases, forKey: .phases)
        try c.encode(lowConfidence, forKey: .lowConfidence)
        try c.encode(candidates, forKey: .candidates)
        try c.encodeIfPresent(jointTrails, forKey: .jointTrails)
        // 保存形式の版 2 と同じ階層に位置合わせのキーを書く
        try transform.encode(to: encoder)
    }

}
