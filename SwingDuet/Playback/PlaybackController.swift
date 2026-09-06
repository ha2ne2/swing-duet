import Foundation
import AVFoundation
import Observation
import QuartzCore
import UIKit

/// 2本の動画を1つの共通タイムラインで駆動する再生コントローラ。
///
/// CADisplayLink をマスタークロックとして共通時刻を進め、各動画は
/// 現在の区間（バックスイング / ダウンスイング / フォロー）ごとの速度倍率で再生する。
/// 区間の切り替わりでレートを更新し、ドリフトが閾値を超えたらシークで補正する。
///
/// NOTE: `ObservableObject` ではなく `@Observable` にしている。`commonTime` は再生中に毎 tick（最大 60Hz）変わるので、
/// `ObservableObject` だと比較画面の View がすべて毎 tick 再描画され、再生中はループ範囲の Menu の項目が押せなくなる
/// （基準の Picker が再生中に効かないのも同じ原因とみている）。`@Observable` なら `commonTime` を読む View（シークバー）だけが再描画される。
@MainActor
@Observable
final class PlaybackController: NSObject {

    /// ループ範囲
    enum LoopMode: Hashable {
        /// スイング全体（アドレス〜フィニッシュ）
        case all
        /// 1 区間だけ
        case segment(SwingSegment)
        /// ループしない（末尾で停止）
        case off

        var segment: SwingSegment? {
            if case .segment(let segment) = self { return segment }
            return nil
        }
    }

    /// タップで切り替える再生速度（この順に巡回する）
    static let speedPresets: [Double] = [0.1, 0.2, 0.3, 0.5, 1.0]
    /// 実時刻と期待時刻のずれがこれ（秒）を超えたらシークで補正する
    private static let driftThreshold = 0.08

    let minePlayer = AVPlayer()
    let modelPlayer = AVPlayer()

    private(set) var commonTime: Double = 0
    private(set) var isPlaying = false
    /// 再生速度（実時間に対する倍率）
    var speed: Double = 0.3 {
        didSet {
            if isPlaying { applyRates() }
        }
    }
    var loop: LoopMode = .all {
        didSet { clampIntoLoop() }
    }
    private(set) var sync: SyncEngine

    // 再生機構の内部状態。View は読まないので観測対象から外す
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var currentSegment: SwingSegment?
    @ObservationIgnored private var wasPlayingBeforeScrub = false

    init(mineURL: URL, modelURL: URL, sync: SyncEngine) {
        self.sync = sync
        super.init()

        for (player, url) in [(minePlayer, mineURL), (modelPlayer, modelURL)] {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
        }
        hardSeek()
    }

    func shutdown() {
        pause()
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - 再生 / 停止

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        let bounds = loopBounds()
        if commonTime >= bounds.end - 0.001 {
            commonTime = bounds.start
        }
        hardSeek()
        isPlaying = true
        currentSegment = sync.segment(at: commonTime)
        applyRates()
        startDisplayLink()
    }

    func pause() {
        guard isPlaying else {
            stopRates()
            return
        }
        isPlaying = false
        stopDisplayLink()
        stopRates()
        hardSeek()
    }

    private func stopRates() {
        minePlayer.rate = 0
        modelPlayer.rate = 0
    }

    // MARK: - 再生速度

    /// speedPresets の次の速度へ（最後の次は最初へ戻る）
    func cycleSpeed() {
        let current = Self.speedPresets.firstIndex(of: speed) ?? -1
        speed = Self.speedPresets[(current + 1) % Self.speedPresets.count]
    }

    // MARK: - シーク / スクラブ

    func beginScrub() {
        wasPlayingBeforeScrub = isPlaying
        if isPlaying {
            isPlaying = false
            stopDisplayLink()
            stopRates()
        }
    }

    func scrub(to time: Double) {
        commonTime = min(max(time, 0), sync.commonDuration)
        seekBoth(precise: false)
    }

    func endScrub() {
        hardSeek()
        if wasPlayingBeforeScrub {
            wasPlayingBeforeScrub = false
            play()
        }
    }

    func jump(to phase: SwingPhase) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        var t = sync.commonTime(of: phase)
        let bounds = loopBounds()
        t = min(max(t, bounds.start), bounds.end)
        commonTime = t
        hardSeek()
        if wasPlaying { play() }
    }

    /// コマ送り（基準側動画の1フレーム単位）
    func stepFrame(by frames: Int) {
        if isPlaying { pause() }
        let bounds = loopBounds()
        let step = sync.referenceFrameDuration * Double(frames)
        commonTime = min(max(commonTime + step, bounds.start), bounds.end)
        hardSeek()
    }

    // MARK: - 同期設定の更新

    /// フェーズ修正・基準切り替え時に呼ぶ。相対位置を保って追従する。
    func updateSync(_ newSync: SyncEngine) {
        guard newSync != sync else { return }
        let fraction = sync.commonDuration > 0 ? commonTime / sync.commonDuration : 0
        sync = newSync
        commonTime = min(max(fraction, 0), 1) * newSync.commonDuration
        clampIntoLoop()
        currentSegment = sync.segment(at: commonTime)
        hardSeek()
        if isPlaying { applyRates() }
    }

    // MARK: - ループ範囲

    func loopBounds() -> (start: Double, end: Double) {
        if let segment = loop.segment {
            let range = sync.commonRange(of: segment)
            return (range.lowerBound, range.upperBound)
        }
        return (0, sync.commonDuration)
    }

    private func clampIntoLoop() {
        let bounds = loopBounds()
        if commonTime < bounds.start || commonTime > bounds.end {
            commonTime = bounds.start
            hardSeek()
            if isPlaying { applyRates() }
        }
    }

    // MARK: - マスタークロック

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard let last = lastTimestamp else { return }
        let dt = now - last
        guard dt > 0, dt < 0.5 else { return }

        commonTime += dt * speed

        let bounds = loopBounds()
        if commonTime >= bounds.end {
            if loop == .off {
                commonTime = bounds.end
                pause()
            } else {
                commonTime = bounds.start
                currentSegment = sync.segment(at: commonTime)
                hardSeek()
                applyRates()
            }
            return
        }

        let segment = sync.segment(at: commonTime)
        if segment != currentSegment {
            currentSegment = segment
            applyRates()
        }
        correctDrift()
    }

    // MARK: - プレーヤー制御

    private func applyRates() {
        let segment = sync.segment(at: commonTime)
        for (player, side) in playerSides() {
            let multiplier = sync.rateMultiplier(for: side, in: segment)
            player.rate = Float(speed * multiplier)
        }
    }

    private func correctDrift() {
        for (player, side) in playerSides() {
            let expected = sync.videoTime(at: commonTime, for: side)
            let actual = player.currentTime().seconds
            if abs(actual - expected) > Self.driftThreshold {
                let tolerance = CMTime(seconds: 0.02, preferredTimescale: 6000)
                player.seek(
                    to: CMTime(seconds: expected, preferredTimescale: 6000),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
            }
        }
    }

    /// 正確なシーク（一時停止時・区間切り替え時）
    private func hardSeek() {
        seekBoth(precise: true)
    }

    private func seekBoth(precise: Bool) {
        let tolerance = precise
            ? CMTime.zero
            : CMTime(seconds: 0.02, preferredTimescale: 6000)
        for (player, side) in playerSides() {
            let t = sync.videoTime(at: commonTime, for: side)
            player.seek(
                to: CMTime(seconds: t, preferredTimescale: 6000),
                toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    private func playerSides() -> [(AVPlayer, ReferenceSide)] {
        [(minePlayer, .mine), (modelPlayer, .model)]
    }

    deinit {
        displayLink?.invalidate()
    }
}
