import SwiftUI
import Photos
import AVFoundation

/// 選んだ 1 本を繰り返し再生して確かめる。
/// スローモーション動画は原本（高フレームレート）を等速で再生する（写真アプリのスロー効果は掛けない）。
/// 映像の下端の細い進捗バーをドラッグして見たい瞬間に寄れる
struct LibraryPreviewView: View {
    let source: LibrarySource
    let destination: VideoSide
    let onUse: () -> Void

    @State private var player: AVPlayer?
    @State private var loadError: String?
    @State private var duration: Double = 0
    @State private var frameRate: Double = 0
    @State private var time: Double = 0
    @State private var isScrubbing = false
    @State private var wasPlaying = false
    @State private var shotAt: Date?
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Color.black
                if let player {
                    PlayerLayerView(player: player)
                } else if let loadError {
                    ContentUnavailableView("動画を読み込めません", systemImage: "video.slash", description: Text(loadError))
                } else {
                    ProgressView("動画を読み込み中…").tint(.white)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topLeading) {
                    if let meta {
                        Text(meta)
                            .videoChip()
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottom) {
                    progressBar
                }
            Button(action: onUse) {
                Text(destination == .mine ? "この動画を使う" : "お手本にする")
                    .font(.headline)
                    .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(player == nil)
            .accessibilityIdentifier("preview.use")
        }
        .padding(20)
        .navigationTitle(shotAt?.compactLabel ?? "プレビュー")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { teardown() }
    }

    /// 「240fps · 0:04」のような表記。フレームレートと長さは読み込んでから
    private var meta: String? {
        guard duration > 0 else { return nil }
        var parts: [String] = []
        if frameRate > 0 { parts.append("\(Int(frameRate.rounded()))fps") }
        parts.append(duration.clockLabel)
        return parts.joined(separator: " · ")
    }

    /// 映像の下端の細い進捗バー。ドラッグでシーク（スクラブ中だけ時刻を出す）
    private var progressBar: some View {
        GeometryReader { geo in
            let scale = TimeScale(duration: duration, width: geo.size.width)
            let width = geo.size.width
            let fraction = duration > 0 ? (time / duration).clamped(to: 0...1) : 0
            ZStack(alignment: .bottomLeading) {
                Color.clear   // タッチ領域
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(height: 4)
                Capsule()
                    .fill(.white)
                    .frame(width: width * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: isScrubbing ? 14 : 10, height: isScrubbing ? 14 : 10)
                    .offset(x: width * fraction - (isScrubbing ? 7 : 5), y: isScrubbing ? 5 : 3)
                if isScrubbing {
                    Text("\(time.clockLabel) / \(duration.clockLabel)")
                        .videoChip(font: .caption.monospacedDigit().bold())
                        .offset(y: -16)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            wasPlaying = (player?.rate ?? 0) > 0
                            player?.pause()
                        }
                        time = scale.time(atX: value.location.x)
                        seek(to: time, precise: false)
                    }
                    .onEnded { _ in
                        seek(to: time, precise: true)
                        isScrubbing = false
                        if wasPlaying { player?.play() }
                    })
        }
        .frame(height: 28)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("シーク")
        .accessibilityValue(time.clockLabel)
    }

    private func seek(to seconds: Double, precise: Bool) {
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.05, preferredTimescale: 6000)
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 6000), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    /// 動画を解いて繰り返し再生を始める。原本は音声付きのままなので、映像だけの合成にしてから再生する
    /// （音声トラックがあるとシークのたびに `currentTime` が止まる。理由は `VideoImporter.stripAudioTrack`）
    private func load() async {
        teardown()
        loadError = nil
        do {
            let asset: AVAsset
            switch source {
            case .asset(let source):
                shotAt = source.creationDate
                guard let original = await PhotoLibrary.requestOriginalAsset(source) else { throw VideoError.unavailable }
                asset = original
            case .file(let url):
                shotAt = await VideoImporter.creationDate(of: url)
                asset = AVURLAsset(url: url)
            }
            let item = try await VideoImporter.playerItem(for: asset)
            let duration = try await item.asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw VideoError.unreadable }
            let track = try await item.asset.loadTracks(withMediaType: .video).first
            let frameRate = Double(try await track?.load(.nominalFrameRate) ?? 0)
            guard frameRate.isFinite else { throw VideoError.unreadable }
            // 画面を離れた後に監視や再生を始めると、後片付けを呼ぶ画面が既に無い
            guard !Task.isCancelled else { return }
            self.duration = duration
            self.frameRate = frameRate
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .none
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600), queue: .main) { current in
                if !isScrubbing, current.seconds.isFinite { time = current.seconds }
            }
            self.player = player
            player.play()
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    private func teardown() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
    }
}
