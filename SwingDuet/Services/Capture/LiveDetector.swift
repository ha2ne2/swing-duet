import Foundation
import CoreGraphics

/// 撮影中の追跡結果（15fps の `PoseFrame`）を 1 枚ずつ受け取り、スイング候補・構え・手の静かさを読む（Vision は含まない純粋計算）。
///
/// 直近 `windowLength` 秒の窓に `detectInterval` ごとに `SwingDetector.detect` を掛け、窓の中で形が安定した候補を `LiveShotJudge` に渡す。
/// 構え（録画を押して打席に立ち、`stanceStillDuration` 静止した）は 1 回だけ判定し、全身が枠に入っているかを返す
/// （打席から画面は見えないので、これを音で知らせる）。設計は docs/design/260912_2251-capture-screen.md §3・§4
struct LiveDetector {
    /// 追跡のレート（撮影のフレームをこの頻度に間引く）
    static let sampleRate = 15.0
    /// 検出に掛ける窓の長さ（秒）
    static let windowLength = 8.0
    /// 検出を掛ける間隔（秒）
    static let detectInterval = 0.5
    /// フレームを残しておく長さ（秒）。決まったショットの範囲の分を仮の解析に使う
    static let retention = 30.0
    /// 候補として登録するには、フィニッシュからこれだけ経っていること（窓の中で形が安定する）
    static let settleAfterFinish = 1.0
    /// 窓の先頭に掛かる候補（アドレスが窓の頭に近い）は形が欠けているので登録しない
    static let windowHeadMargin = 0.3
    /// 構えの判定：人物が見えたまま腰がこの時間動かなければ「構えた」
    static let stanceStillDuration = 2.0
    /// 腰がこれ以上（正規化座標）動いたら静止し直し
    static let stanceStillTolerance: CGFloat = 0.04
    /// 見えている関節の外接矩形が画面の端からこれ以内なら、頭か足が切れているとみなす
    /// （関節は頭頂・足の裏より内側にあるので、少し余裕を取る）
    static let edgeMargin: CGFloat = 0.04
    /// 人物がこの時間見えなければ「いなくなった」（構えの判定をやり直す）
    static let personLostAfter = 3.0
    /// 手が動いている（スイングの途中かもしれない）とみなす手の高さ（`SwingDetector` の「高い」と同じ）と、その判定に使う直近の時間
    static let motionHeight = 0.5
    static let motionLookback = 1.0
    /// 静かさの判定に使う直近の時間と、手首の移動の上限（正規化座標）
    static let quietLookback = 0.5
    static let quietDisplacement: CGFloat = 0.02

    /// 構えの判定の結果
    enum StanceEvent: Equatable {
        /// 全身が枠に入っている
        case seen
        /// 頭か足が枠の外
        case cutOff
    }

    /// フレームを 1 枚足したときの結果
    struct Update: Equatable {
        /// 新しく登録した候補（この時点で切り出して仮に保存し、合図を鳴らす）
        var registered: [SwingCandidate] = []
        /// 本番か素振りかの判定
        var verdicts: [LiveShotJudge.Verdict] = []
        var stance: StanceEvent? = nil
        /// この回の検出で窓の中に見つかった候補すべて（更新も含む）。ログ用
        var observed: [SwingCandidate] = []
    }

    private(set) var frames: [PoseFrame] = []
    private(set) var judge = LiveShotJudge()
    private var nextDetectAt = 0.0
    /// 最後に候補として観測したスイングのフィニッシュ（区切りファイルを閉じる時刻の基準）
    private(set) var lastFinish: Double?
    /// 最後に人物が見えた時刻
    private(set) var lastPersonSeenAt: Double?
    private var stanceJudged = false
    private var stillSince: Double?
    private var stillAnchor: CGPoint?

    init() {}

    /// 人物がいま見えているか（直近 0.5 秒）
    func isPersonVisible(at now: Double) -> Bool {
        lastPersonSeenAt.map { now - $0 <= 0.5 } ?? false
    }

    mutating func add(_ frame: PoseFrame) -> Update {
        let now = frame.time
        frames.append(frame)
        frames.removeAll { $0.time < now - Self.retention }

        var update = Update()
        update.stance = judgeStance(frame)

        if now >= nextDetectAt {
            nextDetectAt = now + Self.detectInterval
            (update.observed, update.registered) = observeCandidates(at: now)
            update.verdicts = judge.verdicts(at: now, inMotion: inMotion(at: now))
        }
        return update
    }

    /// 撮影を止めたとき：待たずに全部決める。直前に見つかった候補も登録して返す
    mutating func flush(at now: Double) -> (registered: [SwingCandidate], verdicts: [LiveShotJudge.Verdict]) {
        let (_, registered) = observeCandidates(at: now)
        return (registered, judge.flush(at: now))
    }

    /// 候補の切り出す範囲（`ShotSplitter` と同じ余白）。判定が出る前に仮に保存するときに使う
    static func range(of candidate: SwingCandidate) -> ClosedRange<Double> {
        max(candidate.phases.address - ShotSplitter.leadIn, 0)...(candidate.phases.finish + ShotSplitter.leadOut)
    }

    /// 体に対する手の高さ（腰 0・首 1）のいまの値。ログ用（腰・首・手首のどれかが無ければ nil）
    func currentHandHeight() -> Double? {
        frames.last.flatMap(handHeight)
    }

    /// 直近 1 秒で手首が見えたフレームの割合。ログ用
    func recentWristCoverage(at now: Double) -> Double {
        let recent = frames.filter { $0.time >= now - 1 }
        return recent.isEmpty ? 0 : Double(recent.filter { $0.wrist != nil }.count) / Double(recent.count)
    }

    /// 範囲の分のフレームを、先頭を 0 にして 1 本の動画として見た追跡結果（仮の解析用）
    func track(in range: ClosedRange<Double>) -> PoseTrack {
        let sliced = frames.filter { range.contains($0.time) }.map { frame in
            var shifted = frame
            shifted.time -= range.lowerBound
            return shifted
        }
        return PoseTrack(frames: PoseTracker.medianFilteredWrists(sliced))
    }

    /// 直近 `motionLookback` 秒に手が高い（スイングの途中かもしれない）
    func inMotion(at now: Double) -> Bool {
        frames.contains { $0.time >= now - Self.motionLookback && (handHeight(of: $0) ?? 0) >= Self.motionHeight }
    }

    /// 直近 `quietLookback` 秒、手が低く動いていない（手首が見えなければ静か）。区切りファイルを閉じてよいかの判定に使う
    func isQuiet(at now: Double) -> Bool {
        let recent = frames.filter { $0.time >= now - Self.quietLookback }
        var previous: CGPoint?
        for frame in recent {
            guard let wrist = frame.wrist else { previous = nil; continue }
            if (handHeight(of: frame) ?? 0) >= Self.motionHeight { return false }
            if let previous, wrist.distance(to: previous) > Self.quietDisplacement { return false }
            previous = wrist
        }
        return true
    }

    // MARK: - 中身

    /// 窓の中で検出し、形が安定した候補を登録する。見つかった候補すべてと、そのうち新しく登録したものを返す
    private mutating func observeCandidates(at now: Double) -> (observed: [SwingCandidate], registered: [SwingCandidate]) {
        let windowStart = now - Self.windowLength
        let window = frames.filter { $0.time >= windowStart }
        guard window.count >= 8 else { return ([], []) }
        let track = PoseTrack(frames: PoseTracker.medianFilteredWrists(window))
        var observed: [SwingCandidate] = []
        var registered: [SwingCandidate] = []
        for candidate in SwingDetector.detect(track: track, duration: now) {
            guard candidate.phases.address >= windowStart + Self.windowHeadMargin,
                  candidate.phases.finish <= now - Self.settleAfterFinish else { continue }
            if judge.observe(candidate) { registered.append(candidate) }
            lastFinish = max(lastFinish ?? 0, candidate.phases.finish)
            observed.append(candidate)
        }
        return (observed, registered)
    }

    /// 構えの判定。人物が見えたまま腰が `stanceStillDuration` 動かなければ 1 回だけ判定し、人物がいなくなるまで判定し直さない
    private mutating func judgeStance(_ frame: PoseFrame) -> StanceEvent? {
        let now = frame.time
        guard let bounds = frame.bodyBounds, let root = frame.root else {
            if let seen = lastPersonSeenAt, now - seen >= Self.personLostAfter {
                stanceJudged = false
                stillSince = nil
            }
            return nil
        }
        lastPersonSeenAt = now
        if let anchor = stillAnchor, stillSince != nil, root.distance(to: anchor) <= Self.stanceStillTolerance {
            // 静止が続いている
        } else {
            stillSince = now
            stillAnchor = root
        }
        guard !stanceJudged, let since = stillSince, now - since >= Self.stanceStillDuration else { return nil }
        stanceJudged = true
        // 静止の間に見えていた関節すべての外接矩形で判定する（1 フレームの欠測に揺れない）
        let rects = frames.filter { $0.time >= since }.compactMap(\.bodyBounds) + [bounds]
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let margin = Self.edgeMargin
        let cutOff = union.minX < margin || union.maxX > 1 - margin || union.minY < margin || union.maxY > 1 - margin
        return cutOff ? .cutOff : .seen
    }

    /// 体に対する手の高さ（腰 0・首 1）。腰・首・手首のどれかが無ければ nil
    private func handHeight(of frame: PoseFrame) -> Double? {
        guard let wrist = frame.wrist, let root = frame.root, let neck = frame.neck else { return nil }
        let torso = abs(Double(neck.y - root.y))
        guard torso > 0 else { return nil }
        return (Double(wrist.y) - Double(root.y)) / torso
    }
}

/// 区切りファイルをいつ閉じるか（純粋計算）。設計は docs/design/260912_1951-in-app-slowmo-capture-and-shot-split.md §4.2。
/// (a) ショットのフィニッシュから `closeAfterFinish` 秒経ち、手が静かなとき。(b) ショットが無いまま `maxLength` 秒経ち、手が静かなとき。
/// 手が静かにならなければ `hardMaxLength` で閉じる（1 ファイルを際限なく大きくしない）
struct SegmentPlanner {
    /// 切り出す範囲の後ろの余白（`ShotSplitter.leadOut` = 1.5 秒）が書き終わった直後
    static let closeAfterFinish = ShotSplitter.leadOut + 0.1
    static let maxLength = 60.0
    static let hardMaxLength = 75.0

    /// いまの区切りの先頭（セッション秒）
    private(set) var segmentStart = 0.0

    init() {}

    func shouldClose(at now: Double, lastFinish: Double?, quiet: Bool) -> Bool {
        let length = now - segmentStart
        if length >= Self.hardMaxLength { return true }
        guard quiet else { return false }
        if length >= Self.maxLength { return true }
        if let finish = lastFinish, finish > segmentStart, now >= finish + Self.closeAfterFinish { return true }
        return false
    }

    mutating func didClose(at now: Double) {
        segmentStart = now
    }
}
