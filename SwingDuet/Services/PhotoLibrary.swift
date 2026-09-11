import Foundation
import Combine
import Photos
import UIKit

/// 写真ライブラリ（PhotoKit）。動画の一覧（権限を求め、限定アクセスで選び直したときなどの変更に追従する）と、原本の書き出し。
///
/// 権限を取る理由は 2 つ。動画だけを撮影日順に並べた自前のピッカーを出すことと、
/// スローモーション動画の原本（120 / 240fps・実速）を取り込むこと（`exportOriginal`）。権限の要らない `PhotosPicker` は
/// スローモーション動画を 30fps のレンダリング版（スロー効果の焼き込み）で渡すので、原本はここからしか取れない
@MainActor
final class PhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// 読み取りの権限（PhotoKit に読み取り専用のレベルは無く、`readWrite` が読み取りの権限）
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// 動画だけを撮影日の新しい順に。権限が無ければ空
    @Published private(set) var assets: [PHAsset] = []

    /// 権限を求め（未決定なら OS のダイアログが出る）、一覧を取り、以後の変更を追う
    func load() async {
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        refetch()
        PHPhotoLibrary.shared().register(self)
    }

    private func refetch() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            assets = []
            return
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        assets = result.objects(at: IndexSet(0..<result.count))
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // 差分は見ず取り直す（動画の一覧は数百件までで、取り直しは十分に速い）
        Task { @MainActor [weak self] in self?.refetch() }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - 一覧以外

    /// 限定アクセス（「写真を選択」で許可）のとき、許可する動画を選び直す OS の画面を出す
    static func presentLimitedLibraryPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    /// 原本のファイルを一時ディレクトリへ書き出す（iCloud にしか無ければダウンロードする）。
    /// スローモーション動画は `.video` が高フレームレートの原本で、`.fullSizeVideo` は編集適用済みの書き出し
    nonisolated static func exportOriginal(_ asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first(where: { $0.type == .fullSizeVideo }) else {
            throw VideoError.noVideoTrack
        }
        let ext = (resource.originalFilename as NSString).pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + (ext.isEmpty ? "mov" : ext))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: dest, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return dest
    }
}

/// ピッカーで選んだ動画の出どころ
enum LibrarySource: Hashable {
    /// 写真ライブラリの動画（権限あり。原本を取り込める）
    case asset(PHAsset)
    /// OS のピッカーが渡した一時ファイル（権限なし。スローモーション動画は 30fps のレンダリング版）
    case file(URL)

    /// 撮影日時（写真ライブラリのメタデータ。OS のピッカー経由なら動画ファイルのメタデータ）。無ければ nil
    var creationDate: Date? {
        get async {
            switch self {
            case .asset(let asset): return asset.creationDate
            case .file(let url): return await VideoImporter.creationDate(of: url)
            }
        }
    }
}

extension PHAsset {
    /// スローモーション撮影（高フレームレート）の動画か
    var isSlowMotion: Bool {
        mediaSubtypes.contains(.videoHighFrameRate)
    }
}
