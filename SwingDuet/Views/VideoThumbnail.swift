import SwiftUI
import AVFoundation

/// 動画の指定時刻のコマを非同期に描くサムネイル（取得できなければ黒のまま）。
/// 枠の縦横比 `aspect` を渡すと、その比に中央で切り出してから描くので枠にぴったり収まる。
/// 渡さなければ動画の比のまま枠に収める（余白は黒。比較画面の `resizeAspect` と同じ見え方）。
///
/// NOTE: `scaledToFill` で枠に合わせると画像が枠からはみ出し、SwiftUI でははみ出した部分が隣のボタンのタッチを奪う。
///       枠の形に切り出した画像を `scaledToFit` で描けば、はみ出しそのものが起きない
struct VideoThumbnail: View {
    let url: URL
    let time: Double
    /// 切り出す縦横比（幅 ÷ 高さ）。nil なら切り出さない
    var aspect: CGFloat? = nil
    /// 生成する画像の最大辺（px）。ペイン全体に出すときは大きめにする
    var maxSize: CGFloat = 256

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSize, height: maxSize)
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            // NOTE: サムネイルは無くても機能に影響しないので、失敗は黒表示にとどめる
            guard let cgImage = try? await generator.image(at: cmTime).image else { return }
            image = UIImage(cgImage: Self.crop(cgImage, to: aspect))
        }
    }

    /// 中央で `aspect`（幅 ÷ 高さ）に切り出す
    private static func crop(_ image: CGImage, to aspect: CGFloat?) -> CGImage {
        guard let aspect else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        if width / height > aspect {
            rect.size.width = height * aspect
            rect.origin.x = (width - rect.width) / 2
        } else {
            rect.size.height = width / aspect
            rect.origin.y = (height - rect.height) / 2
        }
        return image.cropping(to: rect) ?? image
    }
}
