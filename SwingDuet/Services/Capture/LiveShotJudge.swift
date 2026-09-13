import Foundation

/// 撮影中に、ライブ検出が見つけたスイング候補を 1 球ずつ「本番」か「素振り」に決める（純粋計算）。
///
/// 後解析の `ShotSplitter` と同じ規則（フィニッシュから次のアドレスまで `groupGap` 秒以内なら同じ組、組の中で明らかに小さいものは素振り、
/// 残った候補の中央値より明らかに小さいものも素振り）を、「まだ来ていない候補」を待ちながら適用する。
/// 組の最後のフィニッシュから `waitAfterFinish` 秒待って、もっと振り切った候補が来なければ決める。
/// そのセッションで 2 球以上決まった後は、その中央値の 6 割以上の候補は `quickWait` 秒で決める（本番の後に素振りが来ることは稀で、
/// 来ても中央値との比較で捨てられる）。
/// 候補は登録した時点で切り出して仮に保存しているので、判定は「写真ライブラリに移す」か「消す」かを決めるもの。
/// 設計は docs/design/260912_2251-capture-screen.md §4
struct LiveShotJudge {
    /// 候補 1 つの判定。`shot` があれば本番（切り出す範囲付き）、nil なら素振り
    struct Verdict: Equatable {
        var candidate: SwingCandidate
        var shot: Shot?
        /// 決めた時刻（セッション秒）
        var decidedAt: Double
    }

    /// 組の最後のフィニッシュから、もっと振り切った候補を待つ時間（秒）。`ShotSplitter.groupGap` と同じ
    static let waitAfterFinish = ShotSplitter.groupGap
    /// セッションの中央値と比べて本番と分かる候補を決めるまでの時間（秒）
    static let quickWait = 1.0
    /// 同じスイングとみなすインパクトの時刻の差（秒）。窓をずらして検出し直すたびに候補が少しずれるので、その分を吸収する
    static let sameSwingTolerance = 0.5

    /// まだ決めていない候補（アドレスの順）
    private(set) var pending: [SwingCandidate] = []
    /// 本番と決めたスイング（中央値の計算と、同じスイングの二重登録の抑えに使う）
    private(set) var decided: [SwingCandidate] = []
    /// 直前に決めたショットの範囲の終わり（次の範囲と重ねない）
    private var lastRangeEnd = 0.0

    init() {}

    /// 候補を登録する。新しい候補なら true。同じスイング（インパクトが近い）が既にあれば、新しい方（窓が進んで文脈が増えた方）に置き換える。
    /// 決めた分より前の候補は受け付けない
    @discardableResult
    mutating func observe(_ candidate: SwingCandidate) -> Bool {
        let impact = candidate.phases.impact
        if let i = pending.firstIndex(where: { Self.isSameSwing($0, candidate) }) {
            pending[i] = candidate
            return false
        }
        if decided.contains(where: { Self.isSameSwing($0, candidate) }) { return false }
        if let last = decided.last, impact <= last.phases.impact { return false }
        pending.append(candidate)
        pending.sort { $0.phases.address < $1.phases.address }
        return true
    }

    /// 同じスイングか（インパクトの時刻が `sameSwingTolerance` 以内）。仮に保存したクリップと判定を突き合わせるのにも使う
    static func isSameSwing(_ a: SwingCandidate, _ b: SwingCandidate) -> Bool {
        abs(a.phases.impact - b.phases.impact) < sameSwingTolerance
    }

    /// 決められる組があれば決める。`inMotion` は今まさに手が動いている（次のスイングの途中かもしれない）とき true で、その間は待つ
    mutating func verdicts(at now: Double, inMotion: Bool = false) -> [Verdict] {
        decide(at: now, force: false, inMotion: inMotion)
    }

    /// 待たずに全部決める（撮影を止めたとき。もう候補は来ない）
    mutating func flush(at now: Double) -> [Verdict] {
        decide(at: now, force: true, inMotion: false)
    }

    private mutating func decide(at now: Double, force: Bool, inMotion: Bool) -> [Verdict] {
        var results: [Verdict] = []
        while let group = firstGroup() {
            guard force || (!inMotion && isClosed(group, at: now)) else { break }
            pending.removeFirst(group.count)
            results += settle(group, at: now)
        }
        return results
    }

    /// 先頭の候補から、フィニッシュ → 次のアドレスが `groupGap` 以内で続く組
    private func firstGroup() -> [SwingCandidate]? {
        guard let first = pending.first else { return nil }
        var group = [first]
        for candidate in pending.dropFirst() {
            guard let last = group.last, candidate.phases.address - last.phases.finish <= ShotSplitter.groupGap else { break }
            group.append(candidate)
        }
        return group
    }

    /// 組を決めてよいか：最後のフィニッシュから `waitAfterFinish` 経った。または、セッションの中央値と比べて最後の候補が本番と分かり `quickWait` 経った
    private func isClosed(_ group: [SwingCandidate], at now: Double) -> Bool {
        guard let last = group.last else { return false }
        if now >= last.phases.finish + Self.waitAfterFinish { return true }
        if let (rise, peak) = sessionMedians, now >= last.phases.finish + Self.quickWait,
           !ShotSplitter.isPractice(last, rise: rise, peakSpeed: peak) {
            return true
        }
        return false
    }

    /// 本番と決めたスイングの振り上げ・ピーク速度の中央値（2 球以上決まってから）
    private var sessionMedians: (rise: Double, peakSpeed: Double)? {
        guard decided.count >= 2, let rise = decided.map(\.rise).median, let peak = decided.map(\.peakSpeed).median else { return nil }
        return (rise, peak)
    }

    /// 組の中で最も振り切った候補に比べて明らかに小さいものと、セッションの中央値に比べて明らかに小さいものを素振りとし、残りを本番（範囲付き）にする
    private mutating func settle(_ group: [SwingCandidate], at now: Double) -> [Verdict] {
        // 最も振り切った候補：振り上げとピーク速度を組の中の最大で正規化して足す（同程度なら後の候補。本番は素振りの後）
        let maxRise = max(group.map(\.rise).max() ?? 0, 0.001)
        let maxPeak = max(group.map(\.peakSpeed).max() ?? 0, 0.001)
        func score(_ c: SwingCandidate) -> Double { c.rise / maxRise + c.peakSpeed / maxPeak }
        guard let top = group.enumerated().max(by: { a, b in
            let (sa, sb) = (score(a.element), score(b.element))
            return sa == sb ? a.offset < b.offset : sa < sb
        })?.element else { return [] }
        let medians = sessionMedians
        return group.map { swing in
            var isPractice = ShotSplitter.isPractice(swing, rise: top.rise, peakSpeed: top.peakSpeed)
            if let (rise, peak) = medians, ShotSplitter.isPractice(swing, rise: rise, peakSpeed: peak) { isPractice = true }
            let lower = max(swing.phases.address - ShotSplitter.leadIn, lastRangeEnd, 0)
            let upper = swing.phases.finish + ShotSplitter.leadOut
            guard !isPractice, upper > lower else { return Verdict(candidate: swing, shot: nil, decidedAt: now) }
            lastRangeEnd = upper
            decided.append(swing)
            return Verdict(candidate: swing, shot: Shot(range: lower...upper, swing: swing), decidedAt: now)
        }
    }
}
