import Foundation
import Combine

/// 比較の履歴（プロジェクト）と登録済みお手本の永続化（Documents/projects.json・models.json + Documents/Videos/）
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
    }

    func videoURL(for fileName: String) -> URL {
        videosDirectory.appendingPathComponent(fileName)
    }

    // MARK: - 動画ファイル

    /// 一時ファイルをアプリ管理領域へ取り込み、保存ファイル名を返す
    func importVideo(from tempURL: URL) throws -> String {
        let fileName = Self.newFileName(extension: tempURL.pathExtension)
        try fileManager.copyItem(at: tempURL, to: videoURL(for: fileName))
        try? fileManager.removeItem(at: tempURL)
        return fileName
    }

    /// 取り込んだが使わなくなった動画（解析失敗・選び直し）を消す
    func removeVideo(_ fileName: String) {
        try? fileManager.removeItem(at: videoURL(for: fileName))
    }

    /// 動画設定を、動画ファイルを複製して別の持ち主用にする（APFS ではクローンになり、実容量は増えない）。
    /// プロジェクトと登録済みお手本、プロジェクト同士でファイルを共有しないため（参照の数え上げが不要になる）
    func duplicate(_ config: VideoConfig) throws -> VideoConfig {
        var copy = config
        copy.fileName = Self.newFileName(extension: (config.fileName as NSString).pathExtension)
        try fileManager.copyItem(at: videoURL(for: config.fileName), to: videoURL(for: copy.fileName))
        return copy
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
        for idx in offsets {
            removeVideo(projects[idx].mine.fileName)
            removeVideo(projects[idx].model.fileName)
        }
        projects.remove(atOffsets: offsets)
        persistProjects()
    }

    // MARK: - 登録済みお手本

    func model(id: UUID?) -> ModelVideo? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// 解析したばかりの動画設定に名前を付けて登録する。動画ファイルは config のものをそのまま登録側が持つ
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
        guard let idx = models.firstIndex(where: { $0.id == id }) else { return }
        removeVideo(models[idx].config.fileName)
        models.remove(at: idx)
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
