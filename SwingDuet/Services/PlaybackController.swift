import Foundation
import AVFoundation
import Observation
import QuartzCore
import UIKit

/// 2 本の動画を 1 つの共通タイムラインで駆動する再生コントローラ。
///
/// CADisplayLink をマスタークロックとして共通時刻（実秒）を進め、各動画は
/// 現在の区間（バックスイング / ダウンスイング / フォロー）ごとの速度倍率で再生する。
/// 倍率は基準側の速さ（焼き込みスローの戻し）と区間長の比を含むので、`speed` 1.0 でどちらの動画も実速で流れる。
/// 区間の切り替わりでレートを更新し、ドリフトが閾値を超えたらシークで補正する（シーク中の側は補正しない）。
///
/// NOTE: `ObservableObject` ではなく `@Observable` にしている。`commonTime` は再生中に毎 tick（最大 60Hz）変わるので、
/// `ObservableObject` だと比較画面の View がすべて毎 tick 再描画され、再生中はループ範囲の Menu の項目が押せなくなる。
/// `@Observable` なら `commonTime` を読む View（シークバー）だけが再描画される。
@MainActor
@Observable
final class PlaybackController: NSObject {

    /// ループ範囲
    enum LoopMode: Hashable {
        /// スイング全体（アドレス〜フィニッシュ）
        case all
        /// つまみで決めた範囲（メニューの「ダウンスイングのみ」等は区間の両端に置いた範囲）
        case range(LoopRange)
        /// ループしない（末尾で停止）
        case off

        static func segment(_ segment: SwingSegment) -> LoopMode { .range(.segment(segment)) }

        var range: LoopRange? {
            if case .range(let range) = self { return range }
            return nil
        }
    }

    /// タップで切り替える再生速度（この順に巡回する）
    static let speedPresets: [Double] = [0.1, 0.2, 0.3, 0.5, 1.0]
    /// 実時刻と期待時刻のずれがこれ（実秒）を超えたらシークで補正する。動画秒で比べるときは rate を掛ける
    private static let driftThreshold = 0.08
    /// 再生中のシーク（スクラブ・ドリフト補正）の許容幅。ゼロにすると精密シークになり、コマ単位の復号で重くなる
    private static let seekTolerance = CMTime(seconds: 0.02, preferredTimescale: 6000)

    /// 動画を持たない不活性なコントローラ。比較前のステージで、比較画面と同じ操作パネルを飾りとして出すのに使う
    /// （形を真似た別の View を持つと、操作パネルを変えたときに高さがずれる）
    static let placeholder = PlaybackController(sync: SyncEngine(
        minePhases: .fallback(duration: 1), modelPhases: .fallback(duration: 1),
        reference: .model, referenceFrameDuration: 1.0 / 30.0, referenceSlowFactor: 1))

    private let minePlayer = AVPlayer()
    private let modelPlayer = AVPlayer()

    private(set) var commonTime: Double = 0
    private(set) var isPlaying = false
    /// 再生速度（実速に対する倍率。x1 で実世界の速さ。焼き込みスローでも `SyncEngine` が戻す）
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
    /// スクラブ・つまみのドラッグを始めたとき再生中だった（離したら再開する）
    @ObservationIgnored private var wasPlayingBeforeDrag = false
    /// 側ごとの実行中のシーク数（`seek` で増やし、完了ハンドラで減らす）。0 でない側はドリフト補正しない
    @ObservationIgnored private var pendingSeeks: [VideoSide: Int] = [:]
    /// シーク中に時計が動かされた。いまのシークが終わったら最新の位置へシークし直す（`show` 参照）
    @ObservationIgnored private var seekRequested = false

    /// どちらかの側でシークが終わっていない
    private var isSeeking: Bool {
        pendingSeeks.values.contains { $0 > 0 }
    }

    convenience init(mineURL: URL, modelURL: URL, sync: SyncEngine) {
        self.init(sync: sync)
        minePlayer.replaceCurrentItem(with: AVPlayerItem(url: mineURL))
        modelPlayer.replaceCurrentItem(with: AVPlayerItem(url: modelURL))
        hardSeek()
    }

    /// プレーヤーに動画を入れない（`placeholder` 用）
    private init(sync: SyncEngine) {
        self.sync = sync
        super.init()
        for side in VideoSide.allCases {
            let player = player(for: side)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
        }
    }

    func player(for side: VideoSide) -> AVPlayer {
        side == .mine ? minePlayer : modelPlayer
    }

    /// 現在のループ範囲（共通タイムライン上の秒）
    var loopRange: ClosedRange<Double> {
        if let range = loop.range { return sync.commonRange(of: range) }
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

    /// 両方の動画が再生できる状態になってから再生を始める（ステージを開いた直後の自動再生用）。
    /// 準備できる前に rate を立てると最初の数コマが飛ぶので待つ。3 秒待っても準備できなければ始めない（ユーザーが再生ボタンで始められる）
    func playWhenReady() async {
        for _ in 0..<60 where !Task.isCancelled {
            if VideoSide.allCases.allSatisfy({ player(for: $0).currentItem?.status == .readyToPlay }) {
                play()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 時計とレートを止める（シークはしない）
    private func stop() {
        stopDisplayLink()
        isPlaying = false
        for side in VideoSide.allCases { player(for: side).rate = 0 }
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

    /// コマ送り（基準側動画の 1 フレーム単位。ループ範囲の端で止まる）。再生中なら止める。
    /// 取りこぼさないよう、コマ数は時計に足し込んでおく（シークは `show` がまとめる）
    func stepFrame(by frames: Int) {
        stop()
        show(clampedToLoop(commonTime + sync.referenceFrameDuration * Double(frames)))
    }

    /// 時計を time に置いてプレーヤーを精密シークする（ジョグホイール・つまみのドラッグ用）。
    ///
    /// 時計（`commonTime`）はすぐ動かすが、プレーヤーのシークは前のシークが終わってから最新の位置へ 1 回だけ行う。
    /// ジョグホイールを速く回すとコマ送りがシークより速く来る。構わず重ねると後のシークが前のシークを取り消し続け、
    /// 回している間ずっと画面が更新されなくなる
    private func show(_ time: Double) {
        commonTime = time
        currentSegment = sync.segment(at: time)
        if isSeeking {
            seekRequested = true
        } else {
            hardSeek()
        }
    }

    // MARK: - ループ範囲のつまみ

    func beginTrim() {
        wasPlayingBeforeDrag = isPlaying
        stop()
    }

    /// ループ範囲の端を time へ動かす（`LoopRange.move`：最も近いフェーズから整数コマ、反対側と 1 コマ以上離す）。
    /// 時計をその端に置いて両方の映像で端のコマを見せる。範囲が無い（全体 / ループしない）ときは何もしない
    func trim(_ bound: LoopRange.Bound, to time: Double) {
        guard var range = loop.range else { return }
        range.move(bound, to: time, in: sync)
        // 先に時計を端へ置く（`loop` の didSet が範囲外と見て先頭へ動かさないように）
        show(sync.commonTime(of: range[bound]))
        loop = .range(range)
    }

    /// 再生中に始めたなら範囲の先頭から再開する。止まっていたなら時計は端に残す（ジョグホイールで端の前後を確かめられる）
    func endTrim() {
        if wasPlayingBeforeDrag { play() }
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
        wasPlayingBeforeDrag = isPlaying
        stop()
    }

    func scrub(to time: Double) {
        commonTime = min(max(time, 0), sync.commonDuration)
        seekBoth(precise: false)
    }

    func endScrub() {
        if wasPlayingBeforeDrag {
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
        for side in VideoSide.allCases {
            player(for: side).rate = Float(speed * sync.rateMultiplier(for: side, in: segment))
        }
    }

    /// シーク中の側は補正しない。シーク中は `currentTime` が進まないので、それをドリフトと見なして補正すると
    /// そのシークがまた時計を止め、シークが連鎖して映像が止まっては飛ぶ。
    /// 閾値は実秒で揃える：`currentTime` の揺れは実秒でほぼ一定なので、rate 8（1/8 のスローを x1）では動画秒で 8 倍に見える
    private func correctDrift() {
        for side in VideoSide.allCases where pendingSeeks[side, default: 0] == 0 {
            let player = player(for: side)
            let expected = sync.videoTime(at: commonTime, for: side)
            let actual = player.currentTime().seconds
            if abs(actual - expected) > Self.driftThreshold * max(Double(player.rate), 1) {
                seek(side, to: expected, tolerance: Self.seekTolerance)
            }
        }
    }

    /// 許容ゼロの精密シーク。止まった位置を正確に出したいとき（一時停止・ジャンプ・コマ送り・ループ復帰など）。
    /// いまの位置へシークするので、シーク中に来たコマ送りのまとめ待ちもこれで満たされる
    private func hardSeek() {
        seekRequested = false
        seekBoth(precise: true)
    }

    private func seekBoth(precise: Bool) {
        let tolerance = precise ? CMTime.zero : Self.seekTolerance
        for side in VideoSide.allCases {
            seek(side, to: sync.videoTime(at: commonTime, for: side), tolerance: tolerance)
        }
    }

    private func seek(_ side: VideoSide, to seconds: Double, tolerance: CMTime) {
        pendingSeeks[side, default: 0] += 1
        player(for: side).seek(
            to: CMTime(seconds: seconds, preferredTimescale: 6000),
            toleranceBefore: tolerance, toleranceAfter: tolerance
        ) { [weak self] _ in
            // 次のシークに置き換えられて中断したときも（finished = false で）必ず呼ばれる
            Task { @MainActor in self?.seekCompleted(side) }
        }
    }

    private func seekCompleted(_ side: VideoSide) {
        pendingSeeks[side, default: 0] -= 1
        // シーク中に来たコマ送りの分をまとめて 1 回で追いつく
        if seekRequested, !isSeeking { hardSeek() }
    }

    deinit {
        displayLink?.invalidate()
    }
}
