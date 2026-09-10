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

    @State private var player = AVPlayer()
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
            PlayerLayerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topLeading) {
                    if let meta {
                        Text(meta)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
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
            let width = geo.size.width
            let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0
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
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
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
                            wasPlaying = player.rate > 0
                            player.pause()
                        }
                        time = Double(min(max(value.location.x / max(width, 1), 0), 1)) * duration
                        seek(to: time, precise: false)
                    }
                    .onEnded { _ in
                        seek(to: time, precise: true)
                        isScrubbing = false
                        if wasPlaying { player.play() }
                    })
        }
        .frame(height: 28)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("シーク")
        .accessibilityValue(time.clockLabel)
    }

    private func seek(to seconds: Double, precise: Bool) {
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func load() async {
        let item: AVPlayerItem?
        switch source {
        case .asset(let asset):
            shotAt = asset.creationDate
            item = await Self.originalPlayerItem(for: asset)
        case .file(let url):
            shotAt = await VideoImporter.creationDate(of: url)
            item = AVPlayerItem(url: url)
        }
        guard let item else { return }
        duration = (try? await item.asset.load(.duration).seconds) ?? 0
        if let track = try? await item.asset.loadTracks(withMediaType: .video).first {
            frameRate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        }
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.replaceCurrentItem(with: item)
        // 末尾まで行ったら先頭から（繰り返し）
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            player.seek(to: .zero)
            player.play()
        }
        // 再生位置をシークバーへ（スクラブ中は指の位置を優先する）
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600), queue: .main) { current in
            if !isScrubbing { time = current.seconds }
        }
        player.play()
    }

    private func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    /// 写真ライブラリの動画の原本の再生アイテム（iCloud にしか無ければダウンロードする）。取れなければ nil。
    /// `requestPlayerItem` はスロー効果を掛けた編集後の状態を返すので、原本を `requestAVAsset(version: .original)` で取る
    private static func originalPlayerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset.map { AVPlayerItem(asset: $0) })
            }
        }
    }
}
