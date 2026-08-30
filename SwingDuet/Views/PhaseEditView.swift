import SwiftUI
import AVFoundation

/// フェーズ検出結果の手動修正。
/// タイムライン上の4つのマーカー（アドレス / トップ / インパクト / フィニッシュ）を
/// ドラッグして調整し、プレビューで確認する。コマ単位の微調整ボタン付き。
struct PhaseEditView: View {
    @Binding var config: VideoConfig
    let videoURL: URL
    let title: String

    @Environment(\.dismiss) private var dismiss

    @State private var phases: PhaseSet
    @State private var selectedPhase: SwingPhase = .impact
    @State private var player = AVPlayer()

    init(config: Binding<VideoConfig>, videoURL: URL, title: String) {
        self._config = config
        self.videoURL = videoURL
        self.title = title
        self._phases = State(initialValue: config.wrappedValue.phases)
    }

    private var frameDuration: Double {
        config.frameRate > 1 ? 1.0 / config.frameRate : 1.0 / 30.0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                PlayerLayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                VStack(spacing: 6) {
                    timeline
                        .frame(height: 56)
                        .padding(.horizontal, 14)

                    Text("マーカーをドラッグしてフェーズ位置を調整できます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Picker("フェーズ", selection: $selectedPhase) {
                    ForEach(SwingPhase.allCases) { phase in
                        Text(phase.label).tag(phase)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: selectedPhase) { _, phase in
                    seek(to: phases.time(of: phase))
                }

                // コマ単位の微調整
                HStack(spacing: 14) {
                    stepButton(label: "-10", frames: -10)
                    stepButton(label: "-1", frames: -1)
                    VStack(spacing: 2) {
                        Text(String(format: "%.3f 秒", phases.time(of: selectedPhase)))
                            .font(.callout.monospacedDigit())
                        Text("テンポ \(phases.tempoText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 110)
                    stepButton(label: "+1", frames: 1)
                    stepButton(label: "+10", frames: 10)
                }
                .padding(.bottom, 8)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        config.phases = phases
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
                player.isMuted = true
                seek(to: phases.time(of: selectedPhase))
            }
            .onDisappear {
                player.pause()
            }
        }
    }

    // MARK: - タイムライン

    private var timeline: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // 背景：スイング区間の色分け（動画全体に対する位置）
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.systemGray5))
                    .frame(height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)

                segmentBar(from: phases.address, to: phases.top, color: SwingSegment.backswing.color, width: width)
                segmentBar(from: phases.top, to: phases.impact, color: SwingSegment.downswing.color, width: width)
                segmentBar(from: phases.impact, to: phases.finish, color: SwingSegment.follow.color, width: width)

                // マーカー
                ForEach(SwingPhase.allCases) { phase in
                    marker(for: phase, width: width)
                }
            }
            .coordinateSpace(name: "timeline")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = time(atX: value.location.x, width: width)
                        phases.assign(selectedPhase, to: t, duration: config.duration)
                        seek(to: phases.time(of: selectedPhase))
                    })
        }
    }

    private func segmentBar(from: Double, to: Double, color: Color, width: CGFloat) -> some View {
        let x0 = x(for: from, width: width)
        let x1 = x(for: to, width: width)
        return Rectangle()
            .fill(color.opacity(0.8))
            .frame(width: max(x1 - x0, 0), height: 10)
            .frame(maxHeight: .infinity, alignment: .center)
            .offset(x: x0)
    }

    private func marker(for phase: SwingPhase, width: CGFloat) -> some View {
        let isSelected = phase == selectedPhase
        return VStack(spacing: 1) {
            Text(phase.shortLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(isSelected ? Color.accentColor : Color(.systemGray4)))
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color(.systemGray2))
                .frame(width: 2, height: 26)
        }
        .offset(x: x(for: phases.time(of: phase), width: width) - 9)
        .onTapGesture {
            selectedPhase = phase
            seek(to: phases.time(of: phase))
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { value in
                    selectedPhase = phase
                    let t = time(atX: value.location.x, width: width)
                    phases.assign(phase, to: t, duration: config.duration)
                    seek(to: phases.time(of: phase))
                })
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        guard config.duration > 0 else { return 0 }
        return width * CGFloat(min(max(time / config.duration, 0), 1))
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(x / max(width, 1), 0), 1)) * config.duration
    }

    // MARK: - 操作

    private func stepButton(label: String, frames: Int) -> some View {
        Button {
            let t = phases.time(of: selectedPhase) + Double(frames) * frameDuration
            phases.assign(selectedPhase, to: t, duration: config.duration)
            seek(to: phases.time(of: selectedPhase))
        } label: {
            Text("\(label)コマ")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func seek(to time: Double) {
        player.pause()
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 6000),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
