import SwiftUI
import AVFoundation

/// 帯でタップしたショットのリプレイ。動画の実フレームレートを 30fps で流すので 240fps なら 1/8 のスロー。ループで繰り返す。
/// 「削除」と「閉じる」だけ（比較はしない）。録画と検出は続いている
struct ReplayOverlay: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip
    let number: Int
    let isRecording: Bool
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var loadError: String?

    /// 240fps を 30fps で流すと 1/8 のスローになる。その倍率の表示（実速の動画は「実速」）
    private var slowLabel: String {
        SlowFactor.label(max(1, (clip.video.frameRate / 30).rounded()))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(Scrim.heavy)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 10) {
                if isRecording {
                    Label("録画は続いています", systemImage: "record.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                ZStack {
                    Color.black
                    if let player {
                        PlayerLayerView(player: player)
                    } else if let loadError {
                        Text(loadError).font(.footnote).padding()
                    } else {
                        ProgressView().tint(.white)
                    }
                    VStack {
                        HStack {
                            Text("\(number) 球目 · \(clip.sortDate.timeLabel) · \(slowLabel)")
                                .videoChip()
                            Spacer()
                        }
                        .padding(10)
                        Spacer()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 14)
                HStack {
                    Button("削除", role: .destructive, action: onDelete)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                    Spacer()
                    Button(action: onClose) {
                        Text("閉じる")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
            }
            .foregroundStyle(.white)
        }
        .task(id: clip.videoIdentity) {
            teardown()
            loadError = nil
            do {
                let asset = try await store.videoAsset(of: clip)
                let item = try await VideoImporter.playerItem(for: asset)
                guard !Task.isCancelled else { return }
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: item)
                queue.isMuted = true
                queue.rate = Float(min(1, 30 / max(clip.video.frameRate, 30)))
                player = queue
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
        .onDisappear { teardown() }
        .accessibilityIdentifier("capture.replay")
    }
    private func teardown() {
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil
        player = nil
    }

}
