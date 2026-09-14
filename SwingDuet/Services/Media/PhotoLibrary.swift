import Foundation
import AVFoundation
import Combine
import Photos
import UIKit

/// PhotoKit の権限・動画一覧と、原本の取得・保存を担当する。
/// PhotosPicker が渡すスロー効果付き動画ではなく、撮影時の高 fps 原本を読むために PhotoKit を使う。
@MainActor
final class PhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// 読み取りの権限（PhotoKit に読み取り専用のレベルは無く、`readWrite` が読み取りの権限）
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// 動画だけを撮影日の新しい順に。権限が無ければ空
    @Published private(set) var assets: [PHAsset] = []

    /// 監視を登録済みか（`load` はタブを開くたびに呼ばれるので、二重に登録しない）
    private var isObserving = false

    /// 権限を求め（未決定なら OS のダイアログが出る）、一覧を取り、以後の変更を追う
    func load() async {
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        refetch()
        guard !isObserving else { return }
        isObserving = true
        PHPhotoLibrary.shared().register(self)
    }

    /// 一覧を取り直す（設定から戻ったとき。`load` と違って権限は求めない）
    func refresh() {
        refetch()
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

    /// 保存した識別子から動画を引く。`localID` で見つからなければ `cloudID` から引き直す（バックアップの復元で `localIdentifier` は変わる）。
    /// 戻り値の `localID` は引き直したときだけ元と違う（呼び手が保存し直す）。どちらでも見つからなければ nil（写真アプリで消された・許可されていない）
    nonisolated static func fetchVideo(localID: String, cloudID: String?) -> (asset: PHAsset, localID: String)? {
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject {
            return (asset, localID)
        }
        guard let cloudID else { return nil }
        let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: [PHCloudIdentifier(stringValue: cloudID)])
        guard let found = mapping.values.first.flatMap({ try? $0.get() }),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [found], options: nil).firstObject else { return nil }
        return (asset, found)
    }

    /// 動画の `PHCloudIdentifier`（文字列）。取れなければ nil
    nonisolated static func cloudIdentifier(of asset: PHAsset) -> String? {
        let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])
        return mapping[asset.localIdentifier].flatMap { try? $0.get() }?.stringValue
    }

    /// 切り出したショットなどの動画ファイルを写真ライブラリに保存し、アルバム `albumName`（無ければ作る）に入れる。
    /// 戻り値は参照に使う識別子。`creationDate` を渡すと写真アプリでその日時に並ぶ（撮った動画から切り出したショットは元の撮影時刻）。
    /// 限定アクセスではアルバムを作れも引けもしない（PhotoKit の制約）ので、アルバムに入れずに保存する（保存した動画はアプリから読める）
    nonisolated static func saveVideo(at url: URL, creationDate: Date?, albumName: String) async throws -> (localID: String, cloudID: String?) {
        let usesAlbum = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        let existingAlbum = usesAlbum ? PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title == %@", albumName)
            return options
        }()).firstObject : nil
        var localID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            creation.addResource(with: .video, fileURL: url, options: nil)
            creation.creationDate = creationDate
            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            localID = placeholder.localIdentifier
            guard usesAlbum else { return }
            let album = existingAlbum.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            album.addAssets([placeholder] as NSArray)
        }
        guard let localID, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
            throw VideoError.unavailable
        }
        return (localID, cloudIdentifier(of: asset))
    }

    /// 動画の原本（スローモーションなら高フレームレートの実速。写真アプリのスロー効果は掛けない）。
    /// `requestPlayerItem` は編集後の状態を返すので、`requestAVAsset(version: .original)` で取る。取れなければ nil
    /// - networkAccess: iCloud にしか無い動画をダウンロードしてよいか。無くても済む用途（サムネイル）では false にする
    ///   （44pt の絵のために 1 GB の動画を落とさない）
    nonisolated static func requestOriginalAsset(_ asset: PHAsset, networkAccess: Bool = true) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = networkAccess
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }
}

/// ピッカーで選んだ動画の出どころ
enum LibrarySource: Hashable {
    /// 写真ライブラリの動画（権限あり。原本を参照する）
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
