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

/// 動画の速さ（動画秒 ÷ 実秒）。1 = 実速、8 = 1/8 のスロー再生が焼き込まれた動画。
/// 比較画面の再生速度は実速に対する倍率なので、スロー動画はこの値で戻して x1 を実速にする
enum SlowFactor {
    /// 選べる倍率（iPhone のスロー撮影は 120fps → 1/4、240fps → 1/8。YouTube などのスーパースローは 1/16〜1/32）
    static let choices: [Double] = [1, 2, 4, 8, 16, 32]

    /// 実速のダウンスイング（トップ → インパクト）の代表値（秒）。ツアープロは 0.20〜0.33 秒、アマチュアは 0.45 秒程度まで。
    /// 0.37 は倍率の境目を 0.52 / 1.04 / 2.08 / 4.2 / 8.3 秒に置くための値（実速の上限 0.45 × N と、次の倍率の下限 0.6 × N の幾何平均）。
    /// 実速寄りに丸める：倍率を大きく間違えると基準側が何倍速にもなって目立ち、小さく間違える方が害が少ない
    private static let typicalDownswingDuration = 0.37

    /// 表示用のラベル（実速 / 1/2 / 1/4 / …）
    static func label(_ factor: Double) -> String {
        factor == 1 ? "実速" : "1/\(Int(factor.rounded()))"
    }

    /// ダウンスイング長（動画秒）から、スロー再生が焼き込まれた動画の速さを推定する。代表値との log2 距離が最も近い倍率。
    /// 隣の倍率（1/4 と 1/8 など）とは内容から区別できないので提案にとどめ、確定はユーザーの選択
    /// （docs/design/260911_0805-slow-factor-on-clips.md）
    static func estimate(downswingDuration: Double) -> Double {
        guard downswingDuration > 0 else { return 1 }
        let ratio = log2(downswingDuration / typicalDownswingDuration)
        return choices.min { abs(log2($0) - ratio) < abs(log2($1) - ratio) } ?? 1
    }
}

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
    /// 拡大率と位置（pt）。自動フィットからの相対値で、1 と 0 のとき自動フィットどおり
    var scale: Double = 1.0
    var offsetX: Double = 0
    var offsetY: Double = 0
    var phases: PhaseSet
    var lowConfidence: Bool = false
    /// 自動検出で見つかったスイング候補（時系列順）。素振りなど複数のスイングが写る動画で、フェーズ調整画面から選び直せる
    var candidates: [PhaseSet] = []

    /// 拡大率と位置を自動フィットどおり（1 と 0）に戻す
    mutating func resetTransform() {
        scale = 1
        offsetX = 0
        offsetY = 0
    }

    /// 1 フレームの長さ（秒）。コマ送りの単位。フレームレートが取れていなければ 30fps とみなす
    var frameDuration: Double {
        frameRate > 1 ? 1.0 / frameRate : 1.0 / 30.0
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
        case fileName, duration, frameRate, slowFactor, videoAspect, focusRect, scale, offsetX, offsetY, phases, lowConfidence, candidates
    }

    /// 後から追加したキー（candidates / videoAspect / focusRect / slowFactor）が無い保存データも読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        duration = try c.decode(Double.self, forKey: .duration)
        frameRate = try c.decode(Double.self, forKey: .frameRate)
        slowFactor = try c.decodeIfPresent(Double.self, forKey: .slowFactor)
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
