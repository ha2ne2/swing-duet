import Foundation
import Photos
import UIKit

/// 写真ライブラリ（PhotoKit）へのアクセス：権限、動画の一覧、原本の書き出し。
///
/// 権限を取る理由は 2 つ。動画だけを撮影日順に並べた自前のピッカーを出すことと、
/// スローモーション動画の原本（120 / 240fps・実速）を取り込むこと。権限の要らない `PhotosPicker` は
/// スローモーション動画を 30fps のレンダリング版（スロー効果の焼き込み）で渡すので、原本はここからしか取れない
enum PhotoLibrary {

    /// 読み取りの権限（PhotoKit に読み取り専用のレベルは無く、`readWrite` が読み取りの権限）
    static var authorization: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// 動画だけを撮影日の新しい順に
    static func fetchVideos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: options)
    }

    /// 限定アクセス（「写真を選択」で許可）のとき、許可する動画を選び直す OS の画面を出す
    @MainActor
    static func presentLimitedLibraryPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    /// 原本のファイルを一時ディレクトリへ書き出す（iCloud にしか無ければダウンロードする）。
    /// スローモーション動画は `.video` が高フレームレートの原本で、`.fullSizeVideo` は編集適用済みの書き出し
    static func exportOriginal(_ asset: PHAsset) async throws -> URL {
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
}

extension PHAsset {
    /// スローモーション撮影（高フレームレート）の動画か
    var isSlowMotion: Bool {
        mediaSubtypes.contains(.videoHighFrameRate)
    }
}
