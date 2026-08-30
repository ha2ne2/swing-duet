import Foundation
import Combine

/// プロジェクトの永続化（Documents/projects.json + Documents/Videos/）
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ComparisonProject] = []

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var indexURL: URL {
        documentsURL.appendingPathComponent("projects.json")
    }

    var videosDirectory: URL {
        documentsURL.appendingPathComponent("Videos", isDirectory: true)
    }

    init() {
        try? fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        load()
    }

    func videoURL(for fileName: String) -> URL {
        videosDirectory.appendingPathComponent(fileName)
    }

    /// 一時ファイルをアプリ管理領域へ取り込み、保存ファイル名を返す
    func importVideo(from tempURL: URL) throws -> String {
        let ext = tempURL.pathExtension.isEmpty ? "mov" : tempURL.pathExtension
        let fileName = UUID().uuidString + "." + ext
        let dest = videoURL(for: fileName)
        try fileManager.copyItem(at: tempURL, to: dest)
        try? fileManager.removeItem(at: tempURL)
        return fileName
    }

    func add(_ project: ComparisonProject) {
        projects.insert(project, at: 0)
        persist()
    }

    func update(_ project: ComparisonProject) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        guard projects[idx] != project else { return }
        projects[idx] = project
        persist()
    }

    func delete(at offsets: IndexSet) {
        for idx in offsets {
            let p = projects[idx]
            try? fileManager.removeItem(at: videoURL(for: p.mine.fileName))
            try? fileManager.removeItem(at: videoURL(for: p.model.fileName))
        }
        projects.remove(atOffsets: offsets)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ComparisonProject].self, from: data) {
            projects = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(projects) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
