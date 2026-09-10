import SwiftUI
import PhotosUI

/// ピッカーで選ばれた動画（`VideoPickerSheet` の結果）
enum PickedVideo {
    case registered(ModelVideo)
    /// ライブラリの動画（右ペインでは名前を付けて登録する。左ペインでは name は nil）
    case library(URL, name: String?)
}

/// ペインに入れる動画を選ぶシート：登録済みお手本（サムネイル付き）と「ライブラリから選ぶ」。
/// 右ペイン（お手本）でライブラリから選ぶと名前を付けるステップを挟み、解析後に登録済みへ入る。
/// カードの長押しで名前の変更・削除
struct VideoPickerSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let side: VideoSide
    let onPick: (PickedVideo) -> Void

    @State private var libraryItem: PhotosPickerItem?
    @State private var loading = false
    /// 右ペイン用にライブラリから読み込んだ動画。名前を付けてから渡す
    @State private var naming: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let naming {
                    NewModelNameStep(url: naming) { name in
                        finish(.library(naming, name: name))
                    } onBack: {
                        self.naming = nil
                    }
                } else {
                    pickerBody
                }
            }
            .navigationTitle(naming == nil ? (side == .model ? "お手本を選ぶ" : "自分のスイングを選ぶ") : "新しいお手本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onChange(of: libraryItem) { _, item in
                loadMovie(item)
            }
        }
    }

    private var pickerBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.models.isEmpty {
                    Text(side == .model
                         ? "登録済みのお手本はまだありません。ライブラリから選ぶと、名前を付けて登録できます。"
                         : "登録済みのお手本はまだありません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    Text("登録済み")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 16) {
                        ForEach(store.models) { model in
                            ModelCard(model: model, isLastUsed: model.id == store.lastUsedModelID) {
                                finish(.registered(model))
                            }
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            PhotosPicker(selection: $libraryItem, matching: .videos) {
                HStack(spacing: 8) {
                    if loading {
                        ProgressView()
                    } else {
                        Image(systemName: "photo.on.rectangle")
                    }
                    Text(loading ? "読み込み中…" : "ライブラリから選ぶ")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .disabled(loading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func loadMovie(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loading = true
        errorMessage = nil
        Task { @MainActor in
            defer { loading = false }
            do {
                let url = try await item.loadMovieURL()
                if side == .model {
                    naming = url
                } else {
                    finish(.library(url, name: nil))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finish(_ picked: PickedVideo) {
        onPick(picked)
        dismiss()
    }
}

/// ライブラリから選んだお手本に名前を付けるステップ
private struct NewModelNameStep: View {
    let url: URL
    let onConfirm: (String) -> Void
    let onBack: () -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            VideoThumbnail(url: url, time: 0.5, aspect: 140 / 186)
                .frame(width: 140, height: 186)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 12)
            TextField("名前（例: マキロイ・アイアン・正面）", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(confirm)
                .accessibilityIdentifier("modelName")
            Text("次回から「お手本を選ぶ」に並びます。名前が空なら日時を付けます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)   // キーボードで縦が詰まっても 1 行に潰さない
            Button(action: confirm) {
                Text("この名前で使う")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            Button("戻る", action: onBack)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .onAppear { focused = true }
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfirm(trimmed.isEmpty ? "お手本 \(Date().compactLabel)" : trimmed)
    }
}

/// 登録済みお手本のカード（サムネイル・名前・テンポ）。長押しで名前の変更・削除
private struct ModelCard: View {
    @EnvironmentObject private var store: ProjectStore
    let model: ModelVideo
    let isLastUsed: Bool
    let onTap: () -> Void

    @State private var isRenaming = false
    @State private var newName = ""

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                VideoThumbnail(url: store.videoURL(for: model.config.fileName), time: model.config.phases.address, aspect: 1, maxSize: 400)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if isLastUsed {
                            Text("前回")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                                .padding(8)
                        }
                    }
                Text(model.name)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                    .frame(minHeight: 36, alignment: .top)
                    .multilineTextAlignment(.leading)
                Text("テンポ \(model.config.phases.tempoText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.name)
        .contextMenu {
            Button("名前を変更", systemImage: "pencil") {
                newName = model.name
                isRenaming = true
            }
            Button("削除", systemImage: "trash", role: .destructive) {
                store.deleteModel(model.id)
            }
        }
        .alert("名前を変更", isPresented: $isRenaming) {
            TextField("名前", text: $newName)
            Button("保存") { store.renameModel(model.id, to: newName.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Button("キャンセル", role: .cancel) {}
        }
    }
}
