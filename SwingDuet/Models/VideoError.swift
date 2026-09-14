import Foundation

/// 動画を読めないときのエラー（解析・取り込み・写真ライブラリの参照で共通）
enum VideoError: LocalizedError {
    case noVideoTrack
    case unreadable
    /// 写真ライブラリの参照が引けない（写真アプリで消された・アクセスが許可されていない）
    case missingInLibrary
    /// 写真ライブラリにはあるが原本を取れない（iCloud からダウンロードできないなど）
    case unavailable
    /// 長い動画を 1 球ずつに分けて取り込み済み（もう一度選んだ）
    case alreadySplit

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "動画トラックが見つかりませんでした。"
        case .unreadable: return "動画を読み込めませんでした。別の動画を選択してください。"
        case .missingInLibrary: return "写真ライブラリに動画がありません。写真アプリで削除されたか、アクセスが許可されていません。"
        case .unavailable: return "動画を読み込めませんでした。iCloud からダウンロードできない可能性があります。"
        case .alreadySplit: return "この動画は 1 球ずつに分けて取り込み済みです。一覧にそのスイングがあります。"
        }
    }
}
