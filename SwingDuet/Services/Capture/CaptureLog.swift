import Foundation

/// 撮影 1 回分のログ（調査用）。`Documents/CaptureLogs/<日時>.txt` に 1 行ずつ追記する。
/// 人物が見えたか・手の高さ・観測した候補・決めたショット・区切りの切り替え・熱・止めた理由を残し、実機で検出が外れたときに
/// Mac から取り出して（`xcrun devicectl device copy from`）読む。動画の中身や個人情報は書かない
final class CaptureLog {
    private let queue = DispatchQueue(label: "com.ha2ne2.SwingDuet.capture.log", qos: .utility)
    private var handle: FileHandle?
    private let startedAt = Date()

    /// ログの置き場（Documents/CaptureLogs）
    private static var directory: URL {
        URL.documents.appendingPathComponent("CaptureLogs", isDirectory: true)
    }

    init(stamp: String) {
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(stamp).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    /// 1 行書く（どのスレッドからでも）。先頭に開始からの秒を付ける
    func line(_ text: String) {
        let elapsed = Date().timeIntervalSince(startedAt)
        queue.async { [self] in
            let data = Data(String(format: "%8.2f  ", elapsed).utf8) + Data(text.utf8) + Data("\n".utf8)
            do {
                try handle?.write(contentsOf: data)
            } catch {
                // 容量不足でも撮影の停止・保存は続ける。書けないログへの追記だけ止める
                try? handle?.close()
                handle = nil
                print("撮影ログを書き込めません: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        queue.async { [self] in
            try? handle?.close()
            handle = nil
        }
    }
}
