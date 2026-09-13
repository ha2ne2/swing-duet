import SwiftUI

extension BodyPart {
    /// 軌跡の色。部位ごとに色相を変え、同じ色相でトップより前は淡く、トップ以降は濃く塗る
    /// （バックスイングとダウンスイングの弧が重なっても、どちらが行きでどちらが帰りか見分けられる）
    func color(afterTop: Bool) -> Color {
        Color(hue: hue, saturation: afterTop ? 1.0 : 0.45, brightness: afterTop ? 0.85 : 1.0)
    }

    /// 左右の対は近い色相にして「肩の 2 本」「股関節の 2 本」と読めるようにする。
    /// 濃淡はトップの前後に使っているので、左右は色相で分ける
    private var hue: Double {
        switch self {
        case .hands: return 0.13          // 黄
        case .head: return 0.60           // 青
        case .leftShoulder: return 0.95   // 桃
        case .rightShoulder: return 0.80  // 紫
        case .leftHip: return 0.30        // 緑
        case .rightHip: return 0.45       // 青緑
        }
    }
}
