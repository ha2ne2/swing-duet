import Foundation

/// 自動フィットに対する倍率と移動量（pt）。クリップ自身と比較相手で同じ値型を使う。
struct PaneTransform: Codable, Equatable {
    var scale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0

    static let identity = PaneTransform()
}

extension PaneTransform {
    private enum CodingKeys: String, CodingKey { case scale, offsetX, offsetY }

    /// 位置合わせを保存していない動画は自動フィットで表示する
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
    }
}
