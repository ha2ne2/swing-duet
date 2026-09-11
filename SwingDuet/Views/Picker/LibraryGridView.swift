import SwiftUI
import Photos
import PhotosUI

/// 「動画を選ぶ」の「動画」タブ：写真ライブラリの動画だけを撮影日の新しい順に並べた自前のグリッド。
/// 権限の状態で見え方が変わる：許可ならグリッド、限定アクセスなら許可した動画だけ ＋「さらに選ぶ」、
/// 拒否なら設定への案内と OS のピッカー（`PhotosPicker`。権限不要だがスローモーション動画は 30fps 版）
struct LibraryGridView: View {
    let onSelect: (LibrarySource) -> Void

    @StateObject private var library = PhotoLibrary()
    @State private var fallbackItem: PhotosPickerItem?
    @State private var loadingFallback = false
    @State private var errorMessage: String?

    private static let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    /// 撮影日ごとの節（新しい日から）
    private var days: [(day: Date, items: [PHAsset])] {
        library.assets.groupedByDay { $0.creationDate ?? .distantPast }
    }

    var body: some View {
        Group {
            switch library.status {
            case .authorized, .limited:
                grid
            case .denied, .restricted:
                deniedView
            default:
                ProgressView()   // 権限を求めている間
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await library.load() }
        .onChange(of: fallbackItem) { _, item in
            loadFallback(item)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if library.status == .limited {
                    limitedBanner
                }
                if library.assets.isEmpty {
                    Text("動画がありません")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                ForEach(days, id: \.day) { group in
                    Text(group.day.dayLabel)
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    LazyVGrid(columns: Self.columns, spacing: 2) {
                        ForEach(group.items, id: \.localIdentifier) { asset in
                            cell(asset)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.bottom, 20)
        }
        .accessibilityIdentifier("library.grid")
    }

    private func cell(_ asset: PHAsset) -> some View {
        Button {
            onSelect(.asset(asset))
        } label: {
            AssetThumbnail(asset: asset)
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    Text(asset.duration.clockLabel)
                        .font(.caption2.bold())
                        .shadow(radius: 2)
                        .padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if asset.isSlowMotion {
                        Text("スロー")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cellLabel(asset))
        .accessibilityIdentifier("library.cell")
    }

    /// 「ビデオ, 9/10 14:32, 4秒, スロー」。E2E はこのラベルの文字列でセルを選ぶ
    private func cellLabel(_ asset: PHAsset) -> String {
        var parts = ["ビデオ"]
        if let date = asset.creationDate { parts.append(date.compactLabel) }
        parts.append("\(Int(asset.duration.rounded()))秒")
        if asset.isSlowMotion { parts.append("スロー") }
        return parts.joined(separator: ", ")
    }

    private var limitedBanner: some View {
        HStack {
            Text("選択した動画だけ表示しています")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("さらに選ぶ") { PhotoLibrary.presentLimitedLibraryPicker() }
                .font(.footnote.bold())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 44, weight: .light))
                .padding(.top, 40)
            Text("写真へのアクセスが許可されていません")
                .font(.headline)
            Text("設定で許可すると、動画の一覧とスロー撮影の原本が使えます。許可しなくても、写真アプリの画面から 1 本ずつ選べます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("設定を開く")
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            PhotosPicker(selection: $fallbackItem, matching: .videos) {
                HStack(spacing: 8) {
                    if loadingFallback {
                        ProgressView()
                    } else {
                        Image(systemName: "photo.on.rectangle")
                    }
                    Text(loadingFallback ? "読み込み中…" : "写真アプリから選ぶ")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.bordered)
            .disabled(loadingFallback)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// OS のピッカーで選んだ動画を一時ファイルとして受け取り、ライブラリの動画と同じ流れ（プレビュー）へ
    private func loadFallback(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loadingFallback = true
        errorMessage = nil
        Task { @MainActor in
            defer { loadingFallback = false }
            do {
                onSelect(.file(try await item.loadMovieURL()))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
