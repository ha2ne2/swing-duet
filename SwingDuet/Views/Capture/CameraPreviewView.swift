import SwiftUI
import AVFoundation

/// `AVCaptureVideoPreviewLayer` をそのまま表示する。層は端末の向きに合わせて `CaptureController` が回す
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// 層ができたときに渡す（回転の調整に使う）
    let onLayer: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> LayerHostView<AVCaptureVideoPreviewLayer> {
        let view = LayerHostView<AVCaptureVideoPreviewLayer>()
        view.hostedLayer.session = session
        view.hostedLayer.videoGravity = .resizeAspect
        onLayer(view.hostedLayer)
        return view
    }

    func updateUIView(_ uiView: LayerHostView<AVCaptureVideoPreviewLayer>, context: Context) {}
}
