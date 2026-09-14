import Foundation

// 保存場所と一時ファイルの作り方（アプリ内のどこからでも同じ置き場を指すため）

extension URL {
    /// アプリの Documents。保存データ（library.json）・アプリ内にコピーした動画・撮影のログと全体の動画の置き場
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 一時ファイルの行き先（重ならない名前 ＋ 拡張子）。書き出し・切り出し・取り込みの出力に使う
    static func temporary(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    /// 動画ファイルの拡張子。付いていなければ mov（OS のピッカーが拡張子なしで渡すことがある）
    var movieExtension: String {
        pathExtension.isEmpty ? "mov" : pathExtension
    }
}
