import SwiftUI
import Photos

/// 写真ライブラリの動画のサムネイル（PhotoKit が返す縮小画像。取れるまで黒）。親が枠と切り抜きを決める
struct AssetThumbnail: View {
    let asset: PHAsset
    /// 要求する画像の大きさ（pt）。画面の倍率を掛けて px にする
    var targetSize = CGSize(width: 200, height: 200)

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .onAppear(perform: request)
        .onDisappear(perform: cancel)
    }

    private func request() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic   // まず粗い画像、続けて精細な画像が届く
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = UIScreen.main.scale
        let size = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        requestID = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async { image = result }
        }
    }

    private func cancel() {
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
    }
}

/// ライブラリの動画のサムネイル（出どころに応じて PhotoKit か AVFoundation で描く）
struct SourceThumbnail: View {
    let source: LibrarySource

    var body: some View {
        switch source {
        case .asset(let asset):
            AssetThumbnail(asset: asset, targetSize: CGSize(width: 140, height: 186))
        case .file(let url):
            VideoThumbnail(url: url, time: 0.5, aspect: 140 / 186)
        }
    }
}
