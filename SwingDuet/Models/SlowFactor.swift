import Foundation

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
