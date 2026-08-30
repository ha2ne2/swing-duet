import SwiftUI
import PhotosUI

/// 2本の動画を選び、スイング解析を実行してプロジェクトを作成する
struct NewComparisonView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var onCreated: (ComparisonProject) -> Void

    @State private var mineItem: PhotosPickerItem?
    @State private var modelItem: PhotosPickerItem?
    @State private var mineURL: URL?
    @State private var modelURL: URL?
    @State private var mineLoading = false
    @State private var modelLoading = false
    @State private var isAnalyzing = false
    @State private var statusText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("動画を選択") {
                    pickerRow(
                        title: "自分のスイング",
                        systemImage: "person.fill",
                        item: $mineItem,
                        loaded: mineURL != nil,
                        loading: mineLoading)
                    pickerRow(
                        title: "お手本のスイング",
                        systemImage: "star.fill",
                        item: $modelItem,
                        loaded: modelURL != nil,
                        loading: modelLoading)
                }

                Section {
                    if isAnalyzing {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(statusText)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("解析して比較を開始") {
                            create()
                        }
                        .disabled(mineURL == nil || modelURL == nil)
                    }
                } footer: {
                    Text("手首の動きを解析してスイング区間とフェーズ（アドレス / トップ / インパクト / フィニッシュ）を自動検出します。240fpsのスロー動画にも対応しています。検出結果は後から手動で修正できます。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新しい比較")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isAnalyzing)
                }
            }
            .onChange(of: mineItem) { _, item in
                loadMovie(item: item, loading: $mineLoading, url: $mineURL)
            }
            .onChange(of: modelItem) { _, item in
                loadMovie(item: item, loading: $modelLoading, url: $modelURL)
            }
            .interactiveDismissDisabled(isAnalyzing)
        }
    }

    private func pickerRow(
        title: String,
        systemImage: String,
        item: Binding<PhotosPickerItem?>,
        loaded: Bool,
        loading: Bool
    ) -> some View {
        PhotosPicker(selection: item, matching: .videos) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if loading {
                    ProgressView()
                } else if loaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("選択")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isAnalyzing)
    }

    private func loadMovie(item: PhotosPickerItem?, loading: Binding<Bool>, url: Binding<URL?>) {
        guard let item else { return }
        loading.wrappedValue = true
        url.wrappedValue = nil
        errorMessage = nil
        Task { @MainActor in
            do {
                let movie = try await item.loadTransferable(type: ImportedMovie.self)
                url.wrappedValue = movie?.url
                if movie == nil {
                    errorMessage = "動画を読み込めませんでした。別の動画を選択してください。"
                }
            } catch {
                errorMessage = "動画の読み込みに失敗しました：\(error.localizedDescription)"
            }
            loading.wrappedValue = false
        }
    }

    private func create() {
        guard let mineURL, let modelURL else { return }
        isAnalyzing = true
        errorMessage = nil
        Task { @MainActor in
            do {
                statusText = "動画を取り込み中…"
                let mineFile = try store.importVideo(from: mineURL)
                let modelFile = try store.importVideo(from: modelURL)
                let mineStored = store.videoURL(for: mineFile)
                let modelStored = store.videoURL(for: modelFile)

                statusText = "手首の動きを解析中…（少し時間がかかります）"
                async let mineTask = SwingAnalyzer.analyze(url: mineStored)
                async let modelTask = SwingAnalyzer.analyze(url: modelStored)
                let mineResult = try await mineTask
                let modelResult = try await modelTask

                let formatter = DateFormatter()
                formatter.dateFormat = "M/d HH:mm"
                let project = ComparisonProject(
                    name: "比較 \(formatter.string(from: Date()))",
                    mine: VideoConfig(
                        fileName: mineFile,
                        duration: mineResult.duration,
                        frameRate: mineResult.frameRate,
                        phases: mineResult.phases,
                        lowConfidence: mineResult.lowConfidence),
                    model: VideoConfig(
                        fileName: modelFile,
                        duration: modelResult.duration,
                        frameRate: modelResult.frameRate,
                        phases: modelResult.phases,
                        lowConfidence: modelResult.lowConfidence))
                store.add(project)
                isAnalyzing = false
                dismiss()
                onCreated(project)
            } catch {
                isAnalyzing = false
                errorMessage = "解析に失敗しました：\(error.localizedDescription)"
            }
        }
    }
}
