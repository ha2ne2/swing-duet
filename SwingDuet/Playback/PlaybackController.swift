import Foundation
import AVFoundation
import Observation
import QuartzCore
import UIKit

/// 2 本の動画を 1 つの共通タイムラインで駆動する再生コントローラ。
///
/// CADisplayLink をマスタークロックとして共通時刻を進め、各動画は
/// 現在の区間（バックスイング / ダウンスイング / フォロー）ごとの速度倍率で再生する。
/// 区間の切り替わりでレートを更新し、ドリフトが閾値を超えたらシークで補正する（シーク中の側は補正しない）。
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
    /// 再生中のシーク（スクラブ・ドリフト補正）の許容幅。ゼロにすると精密シークになり、コマ単位の復号で重くなる
    private static let seekTolerance = CMTime(seconds: 0.02, preferredTimescale: 6000)

    let minePlayer = AVPlayer()
    let modelPlayer = AVPlayer()

    private(set) var commonTime: Double = 0
    private(set) var isPlaying = false
    /// 再生速度（基準側動画のタイムラインに対する倍率。x1 で基準側の動画を等速で流す）
    var speed: Double = 0.3 {
        didSet {
            if isPlaying { applyRates() }
        }
    }
    /// ループ範囲。範囲の外にいたら先頭へ移る
    var loop: LoopMode = .all {
        didSet {
            if !loopRange.contains(commonTime) { move(to: loopRange.lowerBound) }
        }
    }
    private(set) var sync: SyncEngine

    // 再生機構の内部状態。View は読まないので観測対象から外す
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    /// 直前の tick の区間。変わった tick でだけレートを設定し直す
    @ObservationIgnored private var currentSegment: SwingSegment?
    @ObservationIgnored private var wasPlayingBeforeScrub = false
    /// 側ごとの実行中のシーク数（`seek` で増やし、完了ハンドラで減らす）。0 でない側はドリフト補正しない
    @ObservationIgnored private var pendingSeeks: [ReferenceSide: Int] = [:]

    init(mineURL: URL, modelURL: URL, sync: SyncEngine) {
        self.sync = sync
        super.init()

        for (player, url) in [(minePlayer, mineURL), (modelPlayer, modelURL)] {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
        }
        hardSeek()
    }

    /// 現在のループ範囲（共通タイムライン上の秒）
    var loopRange: ClosedRange<Double> {
        if let segment = loop.segment { return sync.commonRange(of: segment) }
        return 0...sync.commonDuration
    }

    // MARK: - 再生 / 停止

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        if commonTime >= loopRange.upperBound - 0.001 {
            commonTime = loopRange.lowerBound   // 末尾で止まっていたら先頭から
        }
        move(to: commonTime)
        startDisplayLink()
    }

    func pause() {
        stop()
        hardSeek()   // 止まった位置のコマを正確に出す
    }

    /// 時計とレートを止める（シークはしない）
    private func stop() {
        stopDisplayLink()
        isPlaying = false
        minePlayer.rate = 0
        modelPlayer.rate = 0
    }

    // MARK: - 再生速度

    /// speedPresets の次の速度へ（最後の次は最初へ戻る）
    func cycleSpeed() {
        let current = Self.speedPresets.firstIndex(of: speed) ?? -1
        speed = Self.speedPresets[(current + 1) % Self.speedPresets.count]
    }

    // MARK: - 位置の移動

    /// 共通時刻を動かして両プレーヤーを精密シークする。再生中なら区間に応じたレートも設定し直す
    private func move(to time: Double) {
        commonTime = time
        currentSegment = sync.segment(at: time)
        hardSeek()
        if isPlaying { applyRates() }
    }

    private func clampedToLoop(_ time: Double) -> Double {
        min(max(time, loopRange.lowerBound), loopRange.upperBound)
    }

    func jump(to phase: SwingPhase) {
        move(to: clampedToLoop(sync.commonTime(of: phase)))
    }

    /// コマ送り（基準側動画の 1 フレーム単位）。再生中なら止める
    func stepFrame(by frames: Int) {
        stop()
        move(to: clampedToLoop(commonTime + sync.referenceFrameDuration * Double(frames)))
    }

    /// フェーズ修正・基準切り替え時に呼ぶ。相対位置（進捗率）を保って追従する
    func updateSync(_ newSync: SyncEngine) {
        guard newSync != sync else { return }
        let fraction = commonTime / sync.commonDuration
        sync = newSync
        let time = fraction * newSync.commonDuration
        move(to: loopRange.contains(time) ? time : loopRange.lowerBound)
    }

    // MARK: - スクラブ

    func beginScrub() {
        wasPlayingBeforeScrub = isPlaying
        stop()
    }

    func scrub(to time: Double) {
        commonTime = min(max(time, 0), sync.commonDuration)
        seekBoth(precise: false)
    }

    func endScrub() {
        if wasPlayingBeforeScrub {
            play()
        } else {
            hardSeek()
        }
    }

    // MARK: - マスタークロック

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
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
        // 長く止まっていた分（バックグラウンド復帰など）は進めない
        guard dt > 0, dt < 0.5 else { return }

        commonTime += dt * speed

        if commonTime >= loopRange.upperBound {
            if loop == .off {
                commonTime = loopRange.upperBound
                pause()
            } else {
                move(to: loopRange.lowerBound)
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
            player.rate = Float(speed * sync.rateMultiplier(for: side, in: segment))
        }
    }

    /// シーク中の側は補正しない。シーク中は `currentTime` が進まないので、それをドリフトと見なして補正すると
    /// そのシークがまた時計を止め、シークが連鎖して映像が止まっては飛ぶ
    private func correctDrift() {
        for (player, side) in playerSides() where pendingSeeks[side, default: 0] == 0 {
            let expected = sync.videoTime(at: commonTime, for: side)
            let actual = player.currentTime().seconds
            if abs(actual - expected) > Self.driftThreshold {
                seek(player, side: side, to: expected, tolerance: Self.seekTolerance)
            }
        }
    }

    /// 許容ゼロの精密シーク。止まった位置を正確に出したいとき（一時停止・ジャンプ・コマ送り・ループ復帰など）
    private func hardSeek() {
        seekBoth(precise: true)
    }

    private func seekBoth(precise: Bool) {
        let tolerance = precise ? CMTime.zero : Self.seekTolerance
        for (player, side) in playerSides() {
            seek(player, side: side, to: sync.videoTime(at: commonTime, for: side), tolerance: tolerance)
        }
    }

    private func seek(_ player: AVPlayer, side: ReferenceSide, to seconds: Double, tolerance: CMTime) {
        pendingSeeks[side, default: 0] += 1
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 6000),
            toleranceBefore: tolerance, toleranceAfter: tolerance
        ) { [weak self] _ in
            // 次のシークに置き換えられて中断したときも（finished = false で）必ず呼ばれる
            Task { @MainActor in self?.pendingSeeks[side, default: 0] -= 1 }
        }
    }

    private func playerSides() -> [(AVPlayer, ReferenceSide)] {
        [(minePlayer, .mine), (modelPlayer, .model)]
    }

    deinit {
        displayLink?.invalidate()
    }
}
