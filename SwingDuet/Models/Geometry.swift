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

extension CGAffineTransform {
    /// 90° 単位の回転行列を厳密な整数の成分で作る（`init(rotationAngle:)` は cos(π/2) が 6e-17 になり、
    /// `PoseTracker.orientation(from:)` や動画の向きの判定で 0 と比べるときに困る）。90° 単位でなければ `init(rotationAngle:)` と同じ
    static func rotation(degrees: Double) -> CGAffineTransform {
        let quarter = Int((degrees / 90).rounded())
        guard abs(degrees - Double(quarter) * 90) < 0.5 else { return CGAffineTransform(rotationAngle: degrees * .pi / 180) }
        switch ((quarter % 4) + 4) % 4 {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: return .identity
        }
    }
}
