import Foundation

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
