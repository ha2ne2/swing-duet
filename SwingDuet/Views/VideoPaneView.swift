import SwiftUI
import AVFoundation

/// 1本の動画の表示ペイン。
/// ピンチで拡大、ドラッグで位置合わせ、ボタンで左右反転（レフティ・撮影側の違いを吸収）。
struct VideoPaneView: View {
    let player: AVPlayer
    @Binding var config: VideoConfig
    let title: String

    @GestureState private var pinchScale: CGFloat = 1.0
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: player)
                .scaleEffect(
                    x: (config.mirrored ? -1 : 1) * currentScale,
                    y: currentScale)
                .offset(
                    x: config.offsetX + dragTranslation.width,
                    y: config.offsetY + dragTranslation.height)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(panGesture.simultaneously(with: pinchGesture))
        .overlay(alignment: .topLeading) {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Button {
                    config.mirrored.toggle()
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                        .foregroundStyle(config.mirrored ? Color.accentColor : .white)
                }
                Button {
                    config.scale = 1
                    config.offsetX = 0
                    config.offsetY = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.white)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(8)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }

    private var currentScale: CGFloat {
        CGFloat(config.scale) * pinchScale
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                config.scale = min(max(config.scale * Double(value), 0.5), 4.0)
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                config.offsetX += value.translation.width
                config.offsetY += value.translation.height
            }
    }
}
