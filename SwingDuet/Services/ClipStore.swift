import Foundation
import Combine
import Photos

/// クリップ（スイングとお手本）の永続化（Documents/library.json + Documents/Videos/）と、取り込んだ動画の解析キュー。
/// 動画ファイルは取り込み後に書き換えないので、同じ動画を取り込み直したクリップ同士で共有する。
/// JSON のどこからも参照されなくなったファイルは起動時に消す（`removeUnreferencedVideos`）。
///
/// NOTE: JSON の読み書きと後片付けの失敗は `try?` で握りつぶす。読めなければ空の状態から始まり、書けなくても次の保存で上書きされ、
///       消し損ねたファイルは次回起動時にまた対象になる。どれもユーザーに知らせて回復できる種類の失敗ではない
@MainActor
final class ClipStore: ObservableObject {
    /// ★ の無いスイングをいくつまで残すか（超えた分は古い順に消える。一覧のフッターにこの数を出す）
    static let swingLimit = 60

    @Published private(set) var clips: [Clip] = []
    /// 同期の基準側（アプリ全体で 1 つ）
    @Published var reference: VideoSide = .model {
        didSet { if reference != oldValue { persist() } }
    }
    /// 解析を実行中のクリップ
    @Published private(set) var analyzingID: UUID?
    /// 直前に削除したクリップ（「元に戻す」用。次の削除で入れ替わり、再起動で消える）
    @Published private(set) var lastDeleted: [Clip] = []

    private let fileManager = FileManager.default
    private let documentsURL: URL
    /// 解析キューを回すか（単体テストでは回さない）
    private let autoAnalyze: Bool

    private var libraryURL: URL { documentsURL.appendingPathComponent("library.json") }
    private var videosDirectory: URL { documentsURL.appendingPathComponent("Videos", isDirectory: true) }

    /// - documentsURL: 保存先（既定は Documents。単体テストでは一時ディレクトリ）
    init(documentsURL: URL? = nil, autoAnalyze: Bool = true) {
        self.documentsURL = documentsURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.autoAnalyze = autoAnalyze
        try? fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        if let library = read(Library.self, from: libraryURL) {
            load(library)
        } else if let migrated = migrateLegacy() {
            load(migrated)
            removeLegacyFiles()
        }
        removeUnreferencedModels()
        removeUnreferencedVideos()
        processQueue()
    }

    /// 棚に並べないお手本（「今回だけ使う」で入れたもの）は、相手にしているスイングが無くなれば消す
    private func removeUnreferencedModels() {
        let referenced = Set(clips.compactMap { $0.pairing?.partnerID })
        let before = clips.count
        clips.removeAll { $0.role == .model && !$0.isRegistered && !referenced.contains($0.id) }
        if clips.count != before { persist() }
    }

    /// 読み込んだものが古い版なら組み替えて保存し直す
    private func load(_ library: Library) {
        clips = library.clips
        reference = library.reference
        guard library.version < Library.currentVersion else { return }
        if library.version < 2 {
            // 版 2: 動画の速さはユーザーの選択だけを保存し、無ければ推定に従う。
            // 版 1 は推定値（信頼度が低ければ 1）を全クリップに書いていたので、その値のままのものは選択ではないとみなして消す
            for i in clips.indices {
                let video = clips[i].video
                if video.slowFactor == (video.lowConfidence ? 1 : video.estimatedSlowFactor) {
                    clips[i].video.slowFactor = nil
                }
            }
        }
        persist()
    }

    // MARK: - 参照

    func clip(id: UUID?) -> Clip? {
        guard let id else { return nil }
        return clips.first { $0.id == id }
    }

    /// スイング（撮影日時の新しい順）
    var swings: [Clip] {
        clips.filter { $0.role == .swing }.sorted { $0.sortDate > $1.sortDate }
    }

    /// 登録済みのお手本（登録の新しい順。「今回だけ使う」で入れたものは除く）
    var models: [Clip] {
        clips.filter { $0.role == .model && $0.isRegistered }.sorted { $0.createdAt > $1.createdAt }
    }

    /// ★ お気に入り（★ の付いたスイング。お手本の棚にも並ぶ）
    var favorites: [Clip] {
        swings.filter(\.isFavorite)
    }

    /// 同じ写真ライブラリの動画を既に取り込んでいれば、そのクリップ（ファイルと解析結果を共有する元）
    func existingClip(assetID: String?) -> Clip? {
        guard let assetID else { return nil }
        return clips.first { $0.assetID == assetID }
    }

    /// いつものお手本：最後に比べた相手（まだ存在して解析が済んでいるもの）。`excluding` は自分自身を相手にしないため
    func usualPartner(excluding id: UUID? = nil) -> Clip? {
        let recent = clips.compactMap { clip in clip.pairing.map { (partnerID: $0.partnerID, at: $0.pairedAt) } }
            .sorted { $0.at > $1.at }
        for pairing in recent {
            if let partner = clip(id: pairing.partnerID), partner.id != id, partner.isAnalyzed { return partner }
        }
        return nil
    }

    /// クリップの相手：最後に比べた相手 → いつものお手本 → 無し（右ペインが空）の順に解決する
    func partner(of clip: Clip) -> Clip? {
        if let pairing = clip.pairing, let partner = self.clip(id: pairing.partnerID), partner.id != clip.id {
            return partner
        }
        return usualPartner(excluding: clip.id)
    }

    // MARK: - 動画ファイル

    func videoURL(of clip: Clip) -> URL {
        videoURL(for: clip.fileName)
    }

    private func videoURL(for fileName: String) -> URL {
        videosDirectory.appendingPathComponent(fileName)
    }

    /// ライブラリの動画をこの役割で使う。同じ写真ライブラリの動画が同じ役割で既にあればそれを返し（行を増やさない）、
    /// 別の役割で既にあれば動画ファイルを共有し、無ければ原本を取り込む。どちらも `add` で解析待ちに入る。
    /// - registered: お手本を棚に並べるか（「今回だけ使う」なら false）
    func obtain(role: ClipRole, name: String = "", source: LibrarySource, partnerID: UUID? = nil, registered: Bool = true) async throws -> Clip {
        let shotAt = await source.creationDate
        switch source {
        case .asset(let asset):
            let twin = existingClip(assetID: asset.localIdentifier)
            if var existing = twin, existing.role == role {
                if registered {   // もう一度「お手本に追加」されたら棚に並べ、名前を入れていれば付け直す（`update` は変化が無ければ何もしない）
                    existing.isRegistered = true
                    if !name.isEmpty { existing.name = name }
                    update(existing)
                }
                return existing
            }
            let fileName: String
            if let twin {
                fileName = twin.fileName   // 同じ動画を別の役割で持っているので、ファイルを共有する
            } else {
                fileName = try importVideo(from: await PhotoLibrary.exportOriginal(asset))
            }
            return add(role: role, name: name, fileName: fileName, shotAt: shotAt, assetID: asset.localIdentifier,
                       partnerID: partnerID, registered: registered)
        case .file(let url):
            return add(role: role, name: name, fileName: try importVideo(from: url), shotAt: shotAt, assetID: nil,
                       partnerID: partnerID, registered: registered)
        }
    }

    /// 一時ファイルをアプリ管理領域へ移し、保存ファイル名を返す（音声の除去は解析キューが行う）
    private func importVideo(from tempURL: URL) throws -> String {
        let ext = tempURL.pathExtension.isEmpty ? "mov" : tempURL.pathExtension
        let fileName = UUID().uuidString + "." + ext
        try fileManager.moveItem(at: tempURL, to: videoURL(for: fileName))
        return fileName
    }

    /// どのクリップからも参照されていない動画ファイルを消す。
    /// クリップを消すときはファイルに触らず（同じファイルを別のクリップが使っていることがあり、「元に戻す」もできる）、
    /// 起動時にここでまとめて片付ける。取り込みの途中でアプリが終了したときの残りも同じく消える
    private func removeUnreferencedVideos() {
        let referenced = Set(clips.map(\.fileName))
        let stored = (try? fileManager.contentsOfDirectory(atPath: videosDirectory.path)) ?? []
        for name in stored where !referenced.contains(name) {
            try? fileManager.removeItem(at: videoURL(for: name))
        }
    }

    // MARK: - 追加

    /// 取り込んだ動画をクリップとして追加し、解析待ちにする。
    /// 同じ写真ライブラリの動画を解析済みで持っていれば、その解析結果を写して解析を省く。
    /// - partnerID: スイングの相手（nil ならいつものお手本）
    /// - registered: お手本を棚に並べるか
    @discardableResult
    func add(role: ClipRole, name: String = "", fileName: String, shotAt: Date?, assetID: String?, partnerID: UUID? = nil, registered: Bool = true) -> Clip {
        var clip = Clip(role: role, name: name, shotAt: shotAt, assetID: assetID, isRegistered: registered,
                        video: .placeholder(fileName: fileName), analysis: .pending)
        if let twin = existingClip(assetID: assetID), twin.isAnalyzed {
            clip.video = twin.video
            clip.video.fileName = fileName
            clip.video.resetTransform()
            clip.analysis = .done
        }
        if role == .swing, let partner = partnerID.flatMap({ self.clip(id: $0) }) ?? usualPartner() {
            clip.pairing = Pairing(partnerID: partner.id)
        }
        clips.append(clip)
        trimSwings()
        persist()
        processQueue()
        return clip
    }

    /// ★ の無い解析済みのスイングを新しい順に `swingLimit` 本だけ残す
    private func trimSwings() {
        let flowing = swings.filter { !$0.isFavorite && $0.isAnalyzed }
        guard flowing.count > Self.swingLimit else { return }
        let dropped = Set(flowing.dropFirst(Self.swingLimit).map(\.id))
        clips.removeAll { dropped.contains($0.id) }
    }

    // MARK: - 編集

    func update(_ clip: Clip) {
        guard let idx = clips.firstIndex(where: { $0.id == clip.id }), clips[idx] != clip else { return }
        clips[idx] = clip
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard var clip = clip(id: id) else { return }
        clip.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(clip)
    }

    func setFavorite(_ id: UUID, _ isFavorite: Bool) {
        guard var clip = clip(id: id) else { return }
        clip.isFavorite = isFavorite
        update(clip)
    }

    /// 相手を替える。右ペインの位置合わせは自動フィットに戻る（相手が違えば位置も違う）
    func setPartner(of id: UUID, to partnerID: UUID) {
        guard var clip = clip(id: id), clip.pairing?.partnerID != partnerID else { return }
        clip.pairing = Pairing(partnerID: partnerID)
        update(clip)
    }

    /// クリップを消す（動画ファイルは次回起動時に、参照が無ければ消える）。`restoreDeleted` で戻せる
    func delete(_ ids: Set<UUID>) {
        let removed = clips.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        clips.removeAll { ids.contains($0.id) }
        lastDeleted = removed
        persist()
    }

    /// 直前に消したクリップを戻す
    func restoreDeleted() {
        guard !lastDeleted.isEmpty else { return }
        clips.append(contentsOf: lastDeleted)
        lastDeleted = []
        persist()
    }

    func clearDeleted() {
        lastDeleted = []
    }

    /// 解析に失敗したクリップをもう一度解析待ちにする
    func retryAnalysis(_ id: UUID) {
        guard var clip = clip(id: id), case .failed = clip.analysis else { return }
        clip.analysis = .pending
        update(clip)
        processQueue()
    }

    // MARK: - 解析キュー

    /// 解析待ちのクリップを取り込み順に 1 本ずつ解析する（Vision を並列に走らせない）
    private func processQueue() {
        guard autoAnalyze, analyzingID == nil,
              let next = clips.filter({ $0.analysis == .pending }).min(by: { $0.createdAt < $1.createdAt }) else { return }
        analyzingID = next.id
        Task { await analyze(next) }
    }

    private func analyze(_ clip: Clip) async {
        let url = videoURL(of: clip)
        // 解析より先に音声を落とす（解析が保存する duration を、以後ずっと読む書き換え後のファイルから取るため）。
        // 失敗しても解析は続ける（音声付きのまま再生はでき、実機でカクつきが残るだけ）
        do {
            _ = try await VideoImporter.stripAudioTrack(at: url)
        } catch {
            print("音声トラックの除去に失敗: \(clip.fileName) \(error.localizedDescription)")
        }
        let result: Result<VideoConfig, Error>
        do {
            result = .success(try await SwingAnalyzer.analyze(url: url).videoConfig(fileName: clip.fileName))
        } catch {
            result = .failure(error)
        }
        // 解析中に消されていなければ結果を書く
        if let idx = clips.firstIndex(where: { $0.id == clip.id }) {
            switch result {
            case .success(let video):
                clips[idx].video = video
                clips[idx].analysis = .done
            case .failure(let error):
                clips[idx].analysis = .failed(error.localizedDescription)
            }
            persist()
        }
        analyzingID = nil
        processQueue()
    }

    // MARK: - 保存

    private func persist() {
        write(Library(clips: clips, reference: reference), to: libraryURL)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 旧データの移行（Documents/projects.json・models.json）

    /// 比較ペアを保存単位にしていたころの形。左右の動画と基準、右ペインに入れた登録済みお手本との紐付け
    private struct LegacyProject: Decodable {
        var id: UUID
        var createdAt: Date
        var mine: VideoConfig
        var model: VideoConfig
        var reference: VideoSide?
        var modelID: UUID?
    }

    private struct LegacyModel: Decodable {
        var id: UUID
        var name: String
        var createdAt: Date
        var config: VideoConfig
    }

    private var legacyProjectsURL: URL { documentsURL.appendingPathComponent("projects.json") }
    private var legacyModelsURL: URL { documentsURL.appendingPathComponent("models.json") }

    /// 旧データがあればクリップに組み替える。比較の左はスイング、右は登録済みお手本（紐付きがあればそれ、無ければ新しいお手本）。
    /// 右ペインの位置合わせはスイング側の `pairing` へ。基準は最新の比較の値
    private func migrateLegacy() -> Library? {
        let projects = read([LegacyProject].self, from: legacyProjectsURL) ?? []
        let models = read([LegacyModel].self, from: legacyModelsURL) ?? []
        guard !projects.isEmpty || !models.isEmpty else { return nil }

        var clips = models.map { Clip(id: $0.id, role: .model, name: $0.name, createdAt: $0.createdAt, video: $0.config) }
        var reference: VideoSide = .model
        // 旧データは新しい順に並んでいるので、古い比較から順に組み替える（同じ動画のお手本を 1 つにまとめるため）
        for project in projects.reversed() {
            let partnerID = project.modelID.flatMap { id in clips.first { $0.id == id }?.id }
                ?? clips.first { $0.role == .model && $0.fileName == project.model.fileName }?.id
                ?? {
                    var video = project.model
                    video.resetTransform()
                    let model = Clip(role: .model, name: "お手本 \(project.createdAt.compactLabel)", createdAt: project.createdAt, video: video)
                    clips.append(model)
                    return model.id
                }()
            let pairing = Pairing(
                partnerID: partnerID, scale: project.model.scale, offsetX: project.model.offsetX, offsetY: project.model.offsetY,
                pairedAt: project.createdAt)
            clips.append(Clip(id: project.id, role: .swing, createdAt: project.createdAt, video: project.mine, pairing: pairing))
            reference = project.reference ?? .model
        }
        return Library(version: 0, clips: clips, reference: reference)
    }

    private func removeLegacyFiles() {
        try? fileManager.removeItem(at: legacyProjectsURL)
        try? fileManager.removeItem(at: legacyModelsURL)
    }
}
