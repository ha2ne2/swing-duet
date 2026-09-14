import SwiftUI
import AVFoundation

/// `AVPlayerLayer` をそのまま表示する（標準コントロールなし）
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerHostView<AVPlayerLayer> {
        let view = LayerHostView<AVPlayerLayer>()
        view.hostedLayer.player = player
        view.hostedLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: LayerHostView<AVPlayerLayer>, context: Context) {
        if uiView.hostedLayer.player !== player {
            uiView.hostedLayer.player = player
        }
    }
}
