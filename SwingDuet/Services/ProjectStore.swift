import Foundation
import Combine

/// 比較の履歴（プロジェクト）と登録済みお手本の永続化（Documents/projects.json・models.json + Documents/Videos/）。
/// 動画ファイルは取り込み後に書き換えないので、比較や登録済みお手本の間で同じファイルを共有する。
/// JSON のどこからも参照されなくなったファイルは起動時に消す（`removeUnreferencedVideos`）。
///
/// NOTE: JSON の読み書きと後片付けの失敗は `try?` で握りつぶす。読めなければ空の状態から始まり、書けなくても次の保存で上書きされ、
///       消し損ねたファイルは次回起動時にまた対象になる。どれもユーザーに知らせて回復できる種類の失敗ではない
@MainActor
final class ProjectStore: ObservableObject {
    /// 比較の履歴（新しい順）。両方の動画がそろった比較が自動で入る
    @Published private(set) var projects: [ComparisonProject] = []
    /// 登録済みお手本（新しい順）
    @Published private(set) var models: [ModelVideo] = []

    /// 前回の比較で使ったお手本（ピッカーで「前回」と示す）
    var lastUsedModelID: UUID? {
        projects.first { $0.modelID != nil }?.modelID
    }

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var projectsURL: URL {
        documentsURL.appendingPathComponent("projects.json")
    }

    private var modelsURL: URL {
        documentsURL.appendingPathComponent("models.json")
    }

    var videosDirectory: URL {
        documentsURL.appendingPathComponent("Videos", isDirectory: true)
    }

    init() {
        try? fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        projects = read([ComparisonProject].self, from: projectsURL) ?? []
        models = read([ModelVideo].self, from: modelsURL) ?? []
        removeUnreferencedVideos()
    }

    func videoURL(for fileName: String) -> URL {
        videosDirectory.appendingPathComponent(fileName)
    }

    // MARK: - 動画ファイル

    /// 一時ファイルをアプリ管理領域へ取り込み、保存ファイル名を返す。
    /// 音声トラックの除去は時間がかかることがあるので、続けて `stripAudio(_:)` を非同期に呼ぶ
    func importVideo(from tempURL: URL) throws -> String {
        let fileName = Self.newFileName(extension: tempURL.pathExtension)
        try fileManager.moveItem(at: tempURL, to: videoURL(for: fileName))
        return fileName
    }

    /// 取り込んだ動画を映像トラックだけにする（理由は `VideoImporter.stripAudioTrack` 参照）。
    /// 失敗しても取り込みは続ける（音声付きのまま再生はでき、実機でカクつきが残るだけ）
    func stripAudio(_ fileName: String) async {
        do {
            _ = try await VideoImporter.stripAudioTrack(at: videoURL(for: fileName))
        } catch {
            print("音声トラックの除去に失敗: \(fileName) \(error.localizedDescription)")
        }
    }

    /// 取り込んだが使わなくなった動画（解析失敗・選び直し）を消す。まだ比較にも登録にも入っていないものに限る
    func removeVideo(_ fileName: String) {
        try? fileManager.removeItem(at: videoURL(for: fileName))
    }

    /// どの比較・登録済みお手本からも参照されていない動画ファイルを消す。
    /// 履歴や登録を消すときはファイルに触らず（同じファイルを別の比較が使っていることがある）、起動時にここでまとめて片付ける。
    /// 取り込みの途中でアプリが終了したときの残りも同じく消える
    private func removeUnreferencedVideos() {
        let referenced = Set(projects.flatMap { [$0.mine.fileName, $0.model.fileName] } + models.map(\.config.fileName))
        let stored = (try? fileManager.contentsOfDirectory(atPath: videosDirectory.path)) ?? []
        for name in stored where !referenced.contains(name) {
            try? fileManager.removeItem(at: videoURL(for: name))
        }
    }

    // MARK: - 比較の履歴

    func add(_ project: ComparisonProject) {
        projects.insert(project, at: 0)
        persistProjects()
    }

    func update(_ project: ComparisonProject) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        guard projects[idx] != project else { return }
        projects[idx] = project
        persistProjects()
        syncModelPhases(from: project)
    }

    func delete(at offsets: IndexSet) {
        projects.remove(atOffsets: offsets)
        persistProjects()
    }

    // MARK: - 登録済みお手本

    func model(id: UUID?) -> ModelVideo? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// 解析したばかりの動画設定に名前を付けて登録する
    func addModel(name: String, config: VideoConfig) -> ModelVideo {
        let model = ModelVideo(name: name, config: config)
        models.insert(model, at: 0)
        persistModels()
        return model
    }

    func renameModel(_ id: UUID, to name: String) {
        guard let idx = models.firstIndex(where: { $0.id == id }), models[idx].name != name else { return }
        models[idx].name = name
        persistModels()
    }

    func deleteModel(_ id: UUID) {
        models.removeAll { $0.id == id }
        persistModels()
    }

    /// お手本のフェーズ修正を登録元にも反映する（フェーズは動画そのものの性質なので、どの比較で直しても共通）
    private func syncModelPhases(from project: ComparisonProject) {
        guard let idx = models.firstIndex(where: { $0.id == project.modelID }),
              models[idx].config.phases != project.model.phases else { return }
        models[idx].config.phases = project.model.phases
        persistModels()
    }

    // MARK: - 保存

    private static func newFileName(extension ext: String) -> String {
        UUID().uuidString + "." + (ext.isEmpty ? "mov" : ext)
    }

    private func persistProjects() {
        write(projects, to: projectsURL)
    }

    private func persistModels() {
        write(models, to: modelsURL)
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
}
