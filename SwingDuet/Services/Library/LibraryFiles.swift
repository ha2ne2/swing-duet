import Foundation

/// ライブラリの JSON と管理動画のファイル操作。クリップの編集や削除の方針は `ClipStore` が決める。
struct LibraryFiles {
    private let documentsURL: URL
    private let fileManager = FileManager.default
    private var libraryURL: URL { documentsURL.appendingPathComponent("library.json") }
    private var videosDirectory: URL { documentsURL.appendingPathComponent("Videos", isDirectory: true) }

    init(documentsURL: URL) {
        self.documentsURL = documentsURL
        // 作成できない場合は読み込み・保存でも失敗する。既存ファイルを上書きして回復を試みない。
        try? fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
    }

    func videoURL(for fileName: String) -> URL {
        videosDirectory.appendingPathComponent(fileName)
    }

    /// 保存データの読み込みの結果
    enum Load {
        /// 初回起動（ファイルがまだ無い）
        case fresh
        /// 読めた（`Library.hasUnreadableClips` が立っていれば一部のクリップだけ読めなかった）
        case loaded(Library)
        /// ファイルはあるのに解けない（壊れている、または新しい形式で書かれている）
        case unreadable

        /// 保存データが失われている恐れがあるか（このとき動画の後片付けをしてはいけない）
        var isDamaged: Bool {
            switch self {
            case .fresh: return false
            case .loaded(let library): return library.hasUnreadableClips || library.version > Library.currentVersion
            case .unreadable: return true
            }
        }
    }

    func load() -> Load {
        do {
            let data = try Data(contentsOf: libraryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .loaded(try decoder.decode(Library.self, from: data))
        } catch CocoaError.fileReadNoSuchFile {
            // 動画だけ残っている場合は初回とは断定できない。次回起動の掃除で失わないよう書き込みも止める
            let files = (try? fileManager.contentsOfDirectory(atPath: videosDirectory.path)) ?? []
            return files.isEmpty ? .fresh : .unreadable
        } catch {
            return .unreadable
        }
    }

    /// 読めなかった保存データを日時付きで退避する（この後の保存で上書きして失う前に）。
    /// 動画は消していないので、退避したファイルから手で拾い直せる
    func backup() -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "library-\(formatter.string(from: Date()))-\(UUID().uuidString).bak"
        guard (try? fileManager.copyItem(at: libraryURL, to: documentsURL.appendingPathComponent(name))) != nil else { return nil }
        return name
    }

    func save(_ library: Library) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // NOTE: 整形はしない（人が読まない一方、軌跡込みで数 MB あり、メインスレッドで符号化するので 2〜3 割が効く）。
        //       キーの順だけは揃えて、取り出して調べるときに差分が読めるようにする
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(library)
        try data.write(to: libraryURL, options: .atomic)
    }

    /// 一時ファイルをアプリ管理領域へ移し、保存ファイル名を返す（音声の除去は解析キューが行う）。
    /// 写真ライブラリの動画は参照で持つので、ここを通るのは権限が無いときの OS ピッカー経由と、写真ライブラリに保存できなかった切り出し（`persistVideo`）だけ
    func importVideo(from tempURL: URL) throws -> String {
        let fileName = UUID().uuidString + "." + tempURL.movieExtension
        try fileManager.moveItem(at: tempURL, to: videoURL(for: fileName))
        return fileName
    }

    /// どのクリップからも参照されていないコピーの動画ファイルを消す（写真ライブラリの参照にはファイルが無い）。
    /// クリップを消すときはファイルに触らず（同じファイルを別のクリップが使っていることがあり、「元に戻す」もできる）、
    /// 起動時にここでまとめて片付ける。取り込みの途中でアプリが終了したときの残りも同じく消える
    func removeUnreferencedVideos(referenced: Set<String>) {
        let stored = (try? fileManager.contentsOfDirectory(atPath: videosDirectory.path)) ?? []
        for name in stored where !referenced.contains(name) {
            try? fileManager.removeItem(at: videoURL(for: name))
        }
    }

    /// 呼び手が参照の保存成功と他の参照が無いことを確認してから削除する
    func removeVideo(_ fileName: String) {
        // 削除に失敗したファイルは残し、次回の整理に任せる
        try? fileManager.removeItem(at: videoURL(for: fileName))
    }
}
