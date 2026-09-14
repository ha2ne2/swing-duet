import SwiftUI
import AVFoundation

/// `CALayer` の派生クラスをそのまま中身にする `UIView`。`layerClass` を差し替えるので層は view の大きさに追従する。
/// 再生（`AVPlayerLayer`）とカメラのプレビュー（`AVCaptureVideoPreviewLayer`）で使う。
/// ピンチ・ドラッグは SwiftUI 側（`VideoPaneView`）で扱うので、UIKit 側ではタッチを受け取らない
/// （受け取ると、このビューの上で SwiftUI のジェスチャーが認識されなくなる）
final class LayerHostView<Hosted: CALayer>: UIView {
    override static var layerClass: AnyClass { Hosted.self }

    /// NOTE: `layerClass` で指定した型そのものなので、この強制キャストは必ず成功する
    var hostedLayer: Hosted { layer as! Hosted }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    /// Storyboard からは使わない
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
