import SwiftUI

extension SwingSegment {
    /// シークバーとフェーズ調整のタイムラインで区間を塗り分ける色
    var color: Color {
        switch self {
        case .backswing: return .blue
        case .downswing: return .orange
        case .follow: return .green
        }
    }
}
