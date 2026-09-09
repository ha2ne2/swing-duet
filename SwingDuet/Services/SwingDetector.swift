import Foundation
import CoreGraphics

/// 体の大きさを単位にした手の 1 サンプル（手首が見えたフレームだけ）
struct HandSample {
    var time: Double
    /// 手の高さ。腰の高さが 0、首の高さが 1
    var height: Double
    /// 手首の速度（体の大きさ/秒）。直前のサンプルと `SwingDetector.gapDuration` 以上あいていれば（欠測明け）nil
    var speed: Double?
}

/// 1 回のスイング候補（採点の内訳付き）
struct SwingCandidate {
    var phases: PhaseSet
    /// 振り上げの大きさ（手の高さの最大 − アドレスの高さ。体の大きさ単位）
    var rise: Double
    /// スイング中の最大手首速度（体の大きさ/秒）
    var peakSpeed: Double
    /// 手首が見えず、再出現の時刻やテンポの比で置いたフェーズ（手動確認を促す）
    var estimated: Set<SwingPhase>
    /// 「振り切り度」。大きいほど本番スイングらしい（候補の中での相対値。最良の候補が約 1.0）
    var score: Double = 0
}

/// 手首の追跡結果からスイングとフェーズを検出する。
///
/// フェーズは**体に対する手の高さ**で決める（腰 = 0、首 = 1）。高さは撮影方向（正面・後方）にも再生速度にも依存せず、
/// アドレス・インパクト（低い）とトップ・フィニッシュ（高い）がはっきり分かれる。基準点を選ばないので、
/// トップで長く静止してもアドレスと取り違えない。設計と実測値は docs/design/260910_0236-hand-height-phase-detection.md。
///
/// 1 本の動画に素振りなど複数のスイングが写っている前提で、「低くて静止」（アドレス）ごとに候補を作って採点する
/// （最も振り切っている候補を採用するのは呼び出し側。候補はすべて返し、ユーザーが選び直せる）。
///
/// 手首が見えない区間（後方視点ではトップ〜インパクトが体の陰に入る）は、再出現をインパクト、
/// バックスイング : ダウンスイング = 3 : 1 の比でトップに置き、`estimated` に記録する。
enum SwingDetector {

    // しきい値はすべて体の大きさ単位。実測（4 本）はアドレス −0.2〜0.1、トップ・フィニッシュ 0.7〜1.9、アドレスの揺れ 0.25〜0.56/秒
    /// これ未満なら手が「低い」（アドレス・インパクト）
    static let lowHeight = 0.3
    /// これ以上なら手が「高い」（トップ・フィニッシュ）
    static let highHeight = 0.5
    /// アドレスの静止：この速度未満が `addressStillDuration` 続く
    static let stillSpeed = 0.7
    static let addressStillDuration = 0.15
    /// フィニッシュの落ち着き：この速度未満が `finishStillDuration` 続く（フィニッシュは反動で少し動くので静止より緩い）
    static let settleSpeed = 1.5
    static let finishStillDuration = 0.2
    /// トップで止まっている判定：最も高い点からこの時間以上、下り始めが来なければ「止まっている」とみなし、下り始めをトップにする
    static let topHoldDuration = 0.2
    /// 下り始め：高さが下がりながら、この速度以上になったところ（止まったトップでの手の揺れ・ずれは 0.2〜0.9）
    static let descentSpeed = 1.0
    /// 手首が見えない時間がこれ以上なら欠測として扱う（欠測明けのサンプルは速度が nil になる）
    static let gapDuration = 0.2
    /// トップが見えないときの置き場所（バックスイング : ダウンスイング = 3 : 1）
    static let backswingShare = 0.75

    static func detect(track: PoseTrack, duration: Double) -> [SwingCandidate] {
        let samples = handSamples(track: track)
        guard samples.count >= 8 else { return [] }
        let addresses = addressRuns(samples)

        var candidates: [SwingCandidate] = []
        for (i, run) in addresses.enumerated() {
            // 次のアドレスの静止が始まるまでが、この候補の探索範囲
            let end = i + 1 < addresses.count ? addresses[i + 1].lowerBound : samples.count
            let timeBound = i + 1 < addresses.count ? samples[end].time : duration
            if let candidate = swingCandidate(address: run, before: end, timeBound: timeBound, samples: samples, duration: duration) {
                candidates.append(candidate)
            }
        }

        // 採点：振り上げの大きさとピーク速度（候補内の最大で正規化）。同程度なら後のスイング（本番は素振りの後）
        let maxRise = max(candidates.map(\.rise).max() ?? 1, 0.001)
        let maxPeak = max(candidates.map(\.peakSpeed).max() ?? 1, 0.001)
        for i in candidates.indices {
            let order = candidates.count > 1 ? Double(i) / Double(candidates.count - 1) : 0
            candidates[i].score = 0.5 * candidates[i].rise / maxRise + 0.5 * candidates[i].peakSpeed / maxPeak + 0.03 * order
        }
        return candidates
    }

    // MARK: - 手の系列

    /// 手首が見えたフレームの、体の大きさ単位の高さと速度。速度は移動平均（窓 5）で平滑化する
    static func handSamples(track: PoseTrack) -> [HandSample] {
        guard let torso = track.torsoHeight, torso > 0 else { return [] }
        // 腰は毎フレーム取れるとは限らないので、直前（先頭だけ直後）の腰の高さを使う（スイング中ほとんど動かない）
        let rootYs = filled(track.roots.map { $0.map { Double($0.y) } })
        var samples: [HandSample] = []
        var last: (time: Double, point: CGPoint)? = nil
        for (i, point) in track.points.enumerated() {
            guard let point, let rootY = rootYs[i] else { continue }
            let time = track.times[i]
            var speed: Double? = nil
            if let last, time - last.time > 0, time - last.time < gapDuration {
                speed = Double(point.distance(to: last.point)) / (time - last.time) / torso
            }
            samples.append(HandSample(time: time, height: (Double(point.y) - rootY) / torso, speed: speed))
            last = (time, point)
        }
        let raw = samples.map(\.speed)
        for i in samples.indices where raw[i] != nil {
            let window = raw[max(0, i - 2)...min(raw.count - 1, i + 2)].compactMap { $0 }
            samples[i].speed = window.reduce(0, +) / Double(window.count)
        }
        return samples
    }

    /// nil を直前の値で埋める（先頭の nil は最初に現れる値で埋める）
    private static func filled(_ values: [Double?]) -> [Double?] {
        var result = values
        var last: Double? = values.first { $0 != nil } ?? nil
        for i in result.indices {
            if let value = result[i] { last = value } else { result[i] = last }
        }
        return result
    }

    // MARK: - アドレス

    /// 低くて静止しているサンプルの連なり（`addressStillDuration` 以上）。欠測明け（speed nil）は連なりを切る
    static func addressRuns(_ samples: [HandSample]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int? = nil
        func close(at last: Int) {
            if let s = start, samples[last].time - samples[s].time >= addressStillDuration { runs.append(s...last) }
            start = nil
        }
        for i in samples.indices {
            let still = samples[i].height < lowHeight && (samples[i].speed ?? .infinity) < stillSpeed
            if still {
                if start == nil { start = i }
            } else {
                close(at: i - 1)
            }
        }
        close(at: samples.count - 1)
        return runs
    }

    // MARK: - 1 回のスイング

    /// アドレスの静止 `run` から始まるスイングの候補。`end`（次のアドレスの静止の先頭）より先は見ない。
    /// スイングと呼べる形（低い → 高い → 低い → 高い）にならなければ nil
    private static func swingCandidate(
        address run: ClosedRange<Int>, before end: Int, timeBound: Double, samples: [HandSample], duration: Double
    ) -> SwingCandidate? {
        let a = run.upperBound
        guard a + 1 < end else { return nil }
        func firstHigh(from i: Int) -> Int? { (i..<end).first { samples[$0].height >= highHeight } }
        func firstLow(from i: Int) -> Int? { (i..<end).first { samples[$0].height < lowHeight } }
        /// `start` 以降で最初に見える「高い → 低い → 高い」の形
        func shape(from start: Int) -> (up: Int, down: Int, up2: Int)? {
            guard let up = firstHigh(from: start), let down = firstLow(from: up + 1),
                  let up2 = firstHigh(from: down + 1) else { return nil }
            return (up, down, up2)
        }
        // NOTE: 以下の範囲は空でないことが呼び出し側で決まっている（見つけた index の間、または要素があると確認した範囲）ので、
        //       min / max の強制アンラップは安全
        func lowest(in range: Range<Int>) -> Int { range.min { samples[$0].height < samples[$1].height }! }
        /// トップ：範囲内で手が最も高いサンプル。ただしそこから `topHoldDuration` 以上、下り始め（高さが下がって
        /// 速度が `descentSpeed` 以上）が来なければトップで止まっているので、下り始め = 切り返しをトップにする
        func topIndex(in range: Range<Int>) -> Int {
            let peakIdx = range.max { samples[$0].height < samples[$1].height }!
            let peak = samples[peakIdx].height
            let descent = ((peakIdx + 1)..<range.upperBound).first {
                samples[$0].height < peak - 0.02 && (samples[$0].speed ?? 0) >= descentSpeed
            }
            guard let descent, samples[descent].time - samples[peakIdx].time >= topHoldDuration else { return peakIdx }
            return descent
        }

        // 最初の欠測が最初の下りより前にあれば、切り返しが欠測に掛かっているかもしれない。その場合は欠測の後ろから形を読む
        let gap = ((a + 1)..<end).first { samples[$0].speed == nil }
        let firstDescent = firstHigh(from: a + 1).flatMap { firstLow(from: $0 + 1) }
        let gapBeforeDescent = gap.map { $0 <= (firstDescent ?? end) } ?? false

        var estimated: Set<SwingPhase> = []
        let topIdx: Int?   // nil = 見えないので比で置く
        let impactIdx: Int
        let followStart: Int
        if let s = shape(from: (gapBeforeDescent ? gap : nil) ?? (a + 1)) {
            // トップ〜インパクトが見えている（欠測があってもバックスイングの途中で、その後に形が見える）
            topIdx = topIndex(in: s.up..<s.down)
            impactIdx = lowest(in: s.down..<s.up2)
            followStart = s.up2
        } else if gapBeforeDescent, let gap, let up = firstHigh(from: gap) {
            // 切り返しが欠測の中。インパクトは再出現から次に高くなるまでの最低点に置くが、
            // 本当のインパクトは欠測の中かもしれないので推定扱いにする
            impactIdx = lowest(in: gap..<(up + 1))
            estimated.insert(.impact)
            // 消える前に既に高ければトップはそこ、まだ上がり途中なら比で置く
            let before = (a + 1)..<gap
            if before.contains(where: { samples[$0].height >= highHeight }) {
                topIdx = topIndex(in: before)
            } else {
                topIdx = nil
                estimated.insert(.top)
            }
            followStart = up
        } else {
            // 高くならない・高くなったまま戻らない（振り上げただけ）・低いまま終わる（トップからアドレスへ戻すリハーサル）
            return nil
        }

        // フィニッシュ：インパクトの後、高くて落ち着いた状態が finishStillDuration 続く最初のサンプル
        let finishIdx = (followStart..<end).first { settled(from: $0, before: end, samples: samples) }

        let addressTime = max(samples[run.lowerBound].time, samples[a].time - 0.1)
        let impactTime = samples[impactIdx].time
        let topTime = topIdx.map { samples[$0].time } ?? (addressTime + backswingShare * (impactTime - addressTime))
        let finishTime = min(timeBound, (finishIdx.map { samples[$0].time } ?? samples[end - 1].time) + 0.2)
        var phases = PhaseSet(address: addressTime, top: topTime, impact: impactTime, finish: finishTime)
        guard phases.top > phases.address, phases.impact > phases.top, phases.finish > phases.impact else { return nil }
        phases.sanitize(duration: duration)

        let span = a...(finishIdx ?? (end - 1))
        return SwingCandidate(
            phases: phases,
            rise: span.map { samples[$0].height }.max()! - samples[a].height,
            peakSpeed: span.compactMap { samples[$0].speed }.max() ?? 0,
            estimated: estimated)
    }

    /// `i` から、高くて速度が settleSpeed 未満の状態が欠測なしに finishStillDuration 続くか
    private static func settled(from i: Int, before end: Int, samples: [HandSample]) -> Bool {
        var j = i
        while j < end, samples[j].height >= highHeight, (samples[j].speed ?? .infinity) < settleSpeed {
            if samples[j].time - samples[i].time >= finishStillDuration { return true }
            j += 1
        }
        return false
    }
}
