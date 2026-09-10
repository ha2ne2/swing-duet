import SwiftUI
import AVFoundation

/// AVPlayerLayer をそのまま表示する（標準コントロールなし）
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        // NOTE: ピンチ・ドラッグは SwiftUI 側（VideoPaneView）で扱う。UIKit 側でタッチを受け取らないようにして、
        // SwiftUI のジェスチャーがこのビューの上でも確実に認識されるようにする
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    /// NOTE: `layerClass` で AVPlayerLayer を指定しているので、この強制キャストは必ず成功する
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
