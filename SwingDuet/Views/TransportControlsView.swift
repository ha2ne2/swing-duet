import SwiftUI

/// 再生操作パネル：フェーズジャンプ / コマ送り / 再生・停止 / 速度 / ループ
struct TransportControlsView: View {
    @ObservedObject var controller: PlaybackController

    var body: some View {
        VStack(spacing: 10) {
            // フェーズへのジャンプ
            HStack(spacing: 8) {
                ForEach(SwingPhase.allCases) { phase in
                    Button {
                        controller.jump(to: phase)
                    } label: {
                        Text(phase.label)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // 再生・コマ送り・ループ
            HStack(spacing: 22) {
                loopMenu

                Button {
                    controller.stepFrame(by: -1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                        .font(.title3)
                }

                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }

                Button {
                    controller.stepFrame(by: 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.title3)
                }

                Text(String(format: "x%.2f", controller.speed))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44)
            }
            .buttonStyle(.plain)

            // 再生速度 0.1〜1.0
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $controller.speed, in: 0.1...1.0, step: 0.05)
                Image(systemName: "hare.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loopMenu: some View {
        Menu {
            Picker("ループ範囲", selection: loopSelection) {
                Text("スイング全体").tag(LoopChoice.all)
                ForEach(SwingSegment.allCases) { segment in
                    Text("\(segment.label)のみ").tag(LoopChoice.segment(segment))
                }
                Text("ループしない").tag(LoopChoice.off)
            }
        } label: {
            Image(systemName: loopIcon)
                .font(.title3)
                .foregroundStyle(controller.loopEnabled ? Color.accentColor : Color.secondary)
        }
    }

    private var loopIcon: String {
        controller.loopSegment == nil ? "repeat" : "repeat.1"
    }

    private enum LoopChoice: Hashable {
        case all
        case segment(SwingSegment)
        case off
    }

    private var loopSelection: Binding<LoopChoice> {
        Binding {
            if !controller.loopEnabled { return .off }
            if let seg = controller.loopSegment { return .segment(seg) }
            return .all
        } set: { choice in
            switch choice {
            case .all:
                controller.loopEnabled = true
                controller.loopSegment = nil
            case .segment(let seg):
                controller.loopEnabled = true
                controller.loopSegment = seg
            case .off:
                controller.loopEnabled = false
                controller.loopSegment = nil
            }
        }
    }
}
