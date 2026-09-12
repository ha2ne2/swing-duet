import Foundation
import CoreGraphics

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

extension Collection where Element == Double {
    /// 中央値（要素が無ければ nil）。外れ値に引きずられない代表値が要るところで使う
    var median: Double? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        return sorted[sorted.count / 2]
    }
}

extension CGRect {
    /// 点の集まりを囲む最小の矩形。点が無ければ nil
    init?(enclosing points: [CGPoint]) {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
