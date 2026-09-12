import Foundation
import AVFoundation
import Observation
import QuartzCore
import UIKit

/// 2 本の動画を 1 つの共通タイムラインで駆動する再生コントローラ。
///
/// CADisplayLink をマスタークロックとして共通時刻（実秒）を進め、各動画は `SyncEngine` がその時刻に決める速度倍率で再生する
/// （同期しているときは区間ごと、同期しないときは常にその側の速さ）。倍率は焼き込みスローの戻しを含むので、`speed` 1.0 でどちらの動画も実速で流れる。
/// 倍率が変わる tick でレートを更新し、ドリフトが閾値を超えたらシークで補正する（シーク中の側は補正しない）。
///
/// NOTE: `ObservableObject` ではなく `@Observable` にしている。`commonTime` は再生中に毎 tick（最大 60Hz）変わるので、
/// `ObservableObject` だと比較画面の View がすべて毎 tick 再描画され、再生中はループ範囲の Menu の項目が押せなくなる。
/// `@Observable` なら `commonTime` を読む View（シークバー）だけが再描画される。
@MainActor
@Observable
final class PlaybackController: NSObject {

    /// タップで切り替える再生速度（この順に巡回する）
    static let speedPresets: [Double] = [0.1, 0.2, 0.3, 0.5, 1.0]
    /// 実時刻と期待時刻のずれがこれ（実秒）を超えたらシークで補正する。動画秒で比べるときは rate を掛ける
    private static let driftThreshold = 0.08
    /// スクラブとドリフト補正のシークの許容幅。許容ゼロの精密シークは止まった位置のコマを出すときだけ使う（コマ単位の復号で重い）
    private static let seekTolerance = CMTime(seconds: 0.02, preferredTimescale: 6000)

    /// 動画を持たない不活性なコントローラ。比較前のステージで、比較画面と同じ操作パネルを飾りとして出すのに使う
    /// （形を真似た別の View を持つと、操作パネルを変えたときに高さがずれる）
    static let placeholder: PlaybackController = {
        let timing = SyncEngine.Timing(phases: .fallback(duration: 1), slowFactor: 1, frameDuration: 1.0 / 30.0, duration: 1)
        return PlaybackController(mine: timing, model: timing, settings: PlaybackSettings())
    }()

    private let minePlayer = AVPlayer()
    private let modelPlayer = AVPlayer()

    private(set) var commonTime: Double = 0
    private(set) var isPlaying = false
    /// 再生速度（実速に対する倍率。x1 で実世界の速さ。焼き込みスローでも `SyncEngine` が戻す）
    var speed: Double {
        didSet {
            if isPlaying { applyRates() }
        }
    }
    /// ループ範囲。nil ならループしない（末尾で停止）。メニューの「ダウンスイングのみ」等は区間の両端に置いた範囲で、
    /// スイング全体（`LoopRange.all`）も含めどれもシークバーのつまみで端を動かせる。範囲の外にいたら先頭へ移る
    var loop: LoopRange? {
        didSet {
            if !loopRange.contains(commonTime) { move(to: loopRange.lowerBound) }
        }
    }
    private(set) var sync: SyncEngine

    /// 同期のとり方。切り替えると相対位置（進捗率）を保って追従する。
    /// 揃えるフェーズ（`jump(to:)` で替えたもの）は同期しない間だけ引き継ぎ、同期しないに入ったときは既定に戻す
    var syncBasis: SyncBasis {
        get { sync.basis }
        set {
            var newSync = sync
            newSync.basis = newValue
            if newValue == .free, sync.basis != .free { newSync.anchor = PlaybackSettings().anchor }
            replaceSync(newSync)
        }
    }

    /// いまの再生の設定（保存する分。`ComparisonView` が変化を見て `ClipStore` に書く）
    var settings: PlaybackSettings {
        PlaybackSettings(syncBasis: sync.basis, anchor: sync.anchor, speed: speed, loop: loop)
    }

    // 再生機構の内部状態。View は読まないので観測対象から外す
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    /// いまプレーヤーに設定した側ごとの倍率（`applyRates` で更新）。再生中に倍率が変わる tick でだけレートを設定し直す
    @ObservationIgnored private var ratedMultiplier: [VideoSide: Double] = [:]
    /// スクラブ・つまみのドラッグを始めたとき再生中だった（離したら再開する）
    @ObservationIgnored private var wasPlayingBeforeDrag = false
    /// 側ごとの実行中のシーク数（`seek` で増やし、完了ハンドラで減らす）。0 でない側はドリフト補正しない
    @ObservationIgnored private var activeSeeks: [VideoSide: Int] = [:]
    /// シーク中に時計が動かされた（`show`）。値はその要求が精密シークかどうか。いまのシークが終わったら最新の位置へ 1 回だけシークし直す
    @ObservationIgnored private var pendingSeek: Bool?

    /// どちらかの側でシークが終わっていない
    private var isSeeking: Bool {
        activeSeeks.values.contains { $0 > 0 }
    }

    convenience init(mineURL: URL, modelURL: URL, mine: VideoConfig, model: VideoConfig, settings: PlaybackSettings) {
        self.init(mine: SyncEngine.Timing(mine), model: SyncEngine.Timing(model), settings: settings)
        minePlayer.replaceCurrentItem(with: AVPlayerItem(url: mineURL))
        modelPlayer.replaceCurrentItem(with: AVPlayerItem(url: modelURL))
        hardSeek()
    }

    /// プレーヤーに動画を入れない（`placeholder` 用）
    private init(mine: SyncEngine.Timing, model: SyncEngine.Timing, settings: PlaybackSettings) {
        sync = SyncEngine(mine: mine, model: model, basis: settings.syncBasis, anchor: settings.anchor)
        speed = settings.speed
        loop = settings.loop
        super.init()
        commonTime = loopRange.lowerBound   // 復元したループ範囲の先頭から
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

    /// 現在のループ範囲（共通タイムライン上の秒）。ループしないときは末尾で止まるまでの全体
    var loopRange: ClosedRange<Double> {
        sync.commonRange(of: loop ?? .all)
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
        hardSeek()
        if isPlaying { applyRates() }
    }

    private func clampedToLoop(_ time: Double) -> Double {
        min(max(time, loopRange.lowerBound), loopRange.upperBound)
    }

    /// フェーズへ移る。同期しないときはそのフェーズで両方を揃え直してから移る（両方の映像がそのフェーズのコマになる）
    func jump(to phase: SwingPhase) {
        if sync.basis == .free { sync.anchor = phase }
        move(to: clampedToLoop(sync.firstCommonTime(of: phase)))
    }

    /// コマ送り（`SyncEngine.frameStep` 単位。ループ範囲の端で止まる）。再生中なら止める。
    /// 取りこぼさないよう、コマ数は時計に足し込んでおく（シークは `show` がまとめる）
    func stepFrame(by frames: Int) {
        stop()
        show(clampedToLoop(commonTime + sync.frameStep * Double(frames)))
    }

    /// 時計を time に置いてプレーヤーをシークする（ジョグホイール・シークバー・つまみのドラッグ用）。`precise` は許容ゼロ。
    ///
    /// 時計（`commonTime`）はすぐ動かすが、プレーヤーのシークは前のシークが終わってから最新の位置へ 1 回だけ行う（精度は最後の要求のもの）。
    /// ジョグを速く回す・シークバーを速くなぞると、移動がシークより速く来る。後ろへのシークは手前のキーフレームから復号し直すので
    /// 1 回に数十 ms かかり（YouTube 由来のお手本や 240fps の原本はキーフレーム間隔が 120〜235 フレーム）、構わず重ねると
    /// `AVPlayer` は後のシークで前のシークを取り消して復号をやり直し続け、動かしている間ずっと画面が更新されなくなる
    /// （docs/research/260912_0249-seekbar-backward-scrub-stutter.md）。時計は先に動いているので取りこぼしはなく、
    /// 待たせた分は追いつくときに最新の位置へ飛ぶ
    private func show(_ time: Double, precise: Bool = true) {
        commonTime = time
        if isSeeking {
            pendingSeek = precise
        } else {
            seekBoth(precise: precise)
        }
    }

    // MARK: - ループ範囲のつまみ

    func beginTrim() {
        wasPlayingBeforeDrag = isPlaying
        stop()
    }

    /// ループ範囲の端を time へ動かす（`LoopRange.move`：最も近いフェーズから整数コマ、反対側と 1 コマ以上離す）。
    /// 時計をその端に置いて両方の映像で端のコマを見せる。範囲が無い（ループしない）ときは何もしない
    func trim(_ bound: LoopRange.Bound, to time: Double) {
        guard var range = loop else { return }
        range.move(bound, to: time, in: sync)
        // 先に時計を端へ置く（`loop` の didSet が範囲外と見て先頭へ動かさないように）
        show(sync.commonTime(of: range[bound], as: bound))
        loop = range
    }

    /// 再生中に始めたなら範囲の先頭から再開する。止まっていたなら時計は端に残す（ジョグホイールで端の前後を確かめられる）
    func endTrim() {
        if wasPlayingBeforeDrag { play() }
    }

    /// フェーズ修正・動画の速さの選び直しを反映する（同期のとり方と揃えるフェーズはそのまま）
    func updateVideos(mine: VideoConfig, model: VideoConfig) {
        replaceSync(SyncEngine(mine: mine, model: model, basis: sync.basis, anchor: sync.anchor))
    }

    /// 写像を差し替え、相対位置（進捗率）を保って追従する
    private func replaceSync(_ newSync: SyncEngine) {
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
        show(min(max(time, 0), sync.commonDuration), precise: false)
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
            if loop == nil {
                commonTime = loopRange.upperBound
                pause()
            } else {
                move(to: loopRange.lowerBound)
            }
            return
        }

        if VideoSide.allCases.contains(where: { sync.rateMultiplier(for: $0, at: commonTime) != ratedMultiplier[$0] }) { applyRates() }
        correctDrift()
    }

    // MARK: - プレーヤー制御

    /// いまの時刻の倍率と再生速度から両プレーヤーのレートを設定する
    private func applyRates() {
        for side in VideoSide.allCases {
            let multiplier = sync.rateMultiplier(for: side, at: commonTime)
            ratedMultiplier[side] = multiplier
            player(for: side).rate = Float(speed * multiplier)
        }
    }

    /// シーク中の側は補正しない。シーク中は `currentTime` が進まないので、それをドリフトと見なして補正すると
    /// そのシークがまた時計を止め、シークが連鎖して映像が止まっては飛ぶ。
    /// 閾値は実秒で揃える：`currentTime` の揺れは実秒でほぼ一定なので、rate 8（1/8 のスローを x1）では動画秒で 8 倍に見える
    private func correctDrift() {
        for side in VideoSide.allCases where activeSeeks[side, default: 0] == 0 {
            let player = player(for: side)
            let expected = sync.videoTime(at: commonTime, for: side)
            let actual = player.currentTime().seconds
            if abs(actual - expected) > Self.driftThreshold * max(Double(player.rate), 1) {
                seek(side, to: expected, tolerance: Self.seekTolerance)
            }
        }
    }

    /// 許容ゼロの精密シーク。止まった位置を正確に出したいとき（一時停止・ジャンプ・ループ復帰・スクラブ終了など）。
    /// `show` と違って待たずにすぐ出す（走っているシークは取り消される）。いまの位置へ精密に行くので、待たせている移動の要求もこれで満たされる
    private func hardSeek() {
        pendingSeek = nil
        seekBoth(precise: true)
    }

    private func seekBoth(precise: Bool) {
        let tolerance = precise ? CMTime.zero : Self.seekTolerance
        for side in VideoSide.allCases {
            seek(side, to: sync.videoTime(at: commonTime, for: side), tolerance: tolerance)
        }
    }

    private func seek(_ side: VideoSide, to seconds: Double, tolerance: CMTime) {
        activeSeeks[side, default: 0] += 1
        player(for: side).seek(
            to: CMTime(seconds: seconds, preferredTimescale: 6000),
            toleranceBefore: tolerance, toleranceAfter: tolerance
        ) { [weak self] _ in
            // 次のシークに置き換えられて中断したときも（finished = false で）必ず呼ばれる
            Task { @MainActor in self?.seekCompleted(side) }
        }
    }

    private func seekCompleted(_ side: VideoSide) {
        activeSeeks[side, default: 0] -= 1
        // シーク中に来た移動の分をまとめて 1 回で追いつく
        if let precise = pendingSeek, !isSeeking {
            pendingSeek = nil
            seekBoth(precise: precise)
        }
    }

    deinit {
        displayLink?.invalidate()
    }
}
