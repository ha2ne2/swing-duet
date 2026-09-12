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
struct SwingCandidate: Equatable {
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
/// アドレス・インパクト（低い）とトップ・フィニッシュ（高い）がはっきり分かれる。設計は docs/design/260910_0236-hand-height-phase-detection.md。
///
/// **動画の速さに依存しない**ことを原則にする（同設計書 §4.2）。スロー再生が焼き込まれた動画では
/// トップの間が 2 秒に伸び、後方視点ではインパクト付近の手が奥へ動いて画面上は止まって見える。「何秒止まったか」で
/// フェーズやスイングの境目を決めると割れるので、時間の閾値は持たず、高さの形（低い → 高い → 低い → 高い）と
/// 同じ動画の中での速度の比だけで決める。
///
/// 1 本の動画に素振りなど複数のスイングが写っている前提で、手が低い区間から順に形を読んで候補を作り、採点する
/// （最も振り切っている候補を採用するのは呼び出し側。候補はすべて返し、ユーザーが選び直せる）。
///
/// 手首が見えない区間（後方視点ではトップ〜インパクトが体の陰に入る）に切り返しが掛かるときは、再出現をインパクト、
/// バックスイング : ダウンスイング = 3 : 1 の比でトップに置き、`estimated` に記録する。
///
/// ゆっくりした素振りを下ろしてそのまま本番を打つ流れ（練習場で多い）は、インパクト候補で手が止まっているかで見分ける
/// （本物のインパクトで手は止まらない。docs/design/260912_1951-in-app-slowmo-capture-and-shot-split.md §10）。
enum SwingDetector {

    /// これ未満なら手が「低い」（アドレス・インパクト）。実測はアドレス −0.2〜0.1
    private static let lowHeight = 0.3
    /// これ以上なら手が「高い」（トップ・フィニッシュ）。実測は 0.7〜1.9
    private static let highHeight = 0.5
    /// 手首が見えない時間がこれ以上なら欠測として扱う（解析は 30fps なので 6 フレーム。欠測明けのサンプルは速度が nil）
    private static let gapDuration = 0.2
    /// アドレス：低い区間で最も低い高さからこの範囲内にいるサンプルのうち、
    /// 速度がバックスイングの最大の `addressSpeedRatio` 以下（まだ動き出していない）である最後のもの
    private static let restBand = 0.1
    private static let addressSpeedRatio = 0.15
    /// トップ（切り返し）：最も高い点の後、高さが下がりながら速度がダウンスイングの最大のこの割合に達したところ
    private static let descentOnsetRatio = 0.3
    /// フィニッシュ：フォローで手が最も高くなる（そこから `finishDrop` 下がるまでの山の）高さの、この割合に最初に達したところ
    private static let finishHeightRatio = 0.9
    private static let finishDrop = 0.3
    /// フォローの後に手が低く戻る速さが、フォローで上がった速さのこの倍以上なら、その高い区間は別のスイングのトップ
    /// （切り返しの後のダウンスイングは、その前の上がりより速い。フィニッシュから下ろす動きは上がりより遅い）
    private static let anotherSwingRatio = 1.0
    /// トップが見えないときの置き場所（バックスイング : ダウンスイング = 3 : 1）
    private static let backswingShare = 0.75
    /// インパクト付近の低い区間で速度の最小がダウンスイングの最大のこの割合未満なら、手は止まっている = 次のスイングのアドレス（本物のインパクトで手は止まらない）
    private static let impactRestRatio = 0.2
    /// 見えている形を捨てて欠測の中の切り返しに落とすとき、消える前に手がアドレスからこれ以上（体の大きさ単位）上がっていることを要る（テークバック直後の欠測）
    private static let takeawayRise = 0.2

    static func detect(track: PoseTrack, duration: Double) -> [SwingCandidate] {
        let samples = handSamples(track: track)
        guard samples.count >= 8 else { return [] }
        let lows = lowRegions(samples)

        // 低い区間から順に形を読む。スイングが成立したら、そのフィニッシュより後の低い区間から続ける
        // （インパクト付近で手が低く見える区間を、次のスイングのアドレスと取り違えないため）
        var candidates: [SwingCandidate] = []
        var i = 0
        while i < lows.count {
            if let (candidate, finishIdx) = swingCandidate(from: lows[i], samples: samples, duration: duration) {
                candidates.append(candidate)
                i = lows.firstIndex { $0.lowerBound > finishIdx } ?? lows.count
            } else {
                i += 1
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
        // 腰は毎フレーム取れるとは限らないので、直前に取れた腰の高さを使う（スイング中ほとんど動かない。先頭は最初に取れたもの）
        var rootY = track.frames.first { $0.root != nil }?.root.map { Double($0.y) }
        var samples: [HandSample] = []
        var last: (time: Double, point: CGPoint)? = nil
        for frame in track.frames {
            if let root = frame.root { rootY = Double(root.y) }
            guard let wrist = frame.wrist, let rootY else { continue }
            var speed: Double? = nil
            if let last, frame.time - last.time > 0, frame.time - last.time < gapDuration {
                speed = Double(wrist.distance(to: last.point)) / (frame.time - last.time) / torso
            }
            samples.append(HandSample(time: frame.time, height: (Double(wrist.y) - rootY) / torso, speed: speed))
            last = (frame.time, wrist)
        }
        let raw = samples.map(\.speed)
        for i in samples.indices where raw[i] != nil {
            let window = raw[max(0, i - 2)...min(raw.count - 1, i + 2)].compactMap { $0 }
            samples[i].speed = window.reduce(0, +) / Double(window.count)
        }
        return samples
    }

    /// 手が低い（height < lowHeight）サンプルの連なり
    private static func lowRegions(_ samples: [HandSample]) -> [ClosedRange<Int>] {
        var regions: [ClosedRange<Int>] = []
        var start: Int? = nil
        for i in samples.indices {
            if samples[i].height < lowHeight {
                if start == nil { start = i }
            } else if let s = start {
                regions.append(s...(i - 1))
                start = nil
            }
        }
        if let s = start { regions.append(s...(samples.count - 1)) }
        return regions
    }

    // MARK: - 1 回のスイング

    /// 手が低い区間 `low` をアドレスとするスイングの候補と、そのフィニッシュのサンプル添字。
    /// スイングと呼べる形（低い → 高い → 低い → 高い）にならなければ nil
    private static func swingCandidate(
        from low: ClosedRange<Int>, samples: [HandSample], duration: Double
    ) -> (SwingCandidate, finishIdx: Int)? {
        let end = samples.count
        func firstHigh(from i: Int) -> Int? { (i..<end).first { samples[$0].height >= highHeight } }
        func firstLow(from i: Int) -> Int? { (i..<end).first { samples[$0].height < lowHeight } }
        /// `start` 以降で最初に見える「高い → 低い → 高い」の形
        func shape(from start: Int) -> (up: Int, down: Int, up2: Int)? {
            guard let up = firstHigh(from: start), let down = firstLow(from: up + 1),
                  let up2 = firstHigh(from: down + 1) else { return nil }
            return (up, down, up2)
        }
        func maxSpeed(in range: Range<Int>) -> Double { range.compactMap { samples[$0].speed }.max() ?? 0 }
        // NOTE: 以下の範囲は空でないことが呼び出し側で決まっている（見つけた index の間、または要素があると確認した範囲）ので、
        //       min / max の強制アンラップは安全
        func lowest(in range: Range<Int>) -> Int { range.min { samples[$0].height < samples[$1].height }! }
        /// トップ：範囲内で手が最も高いサンプル。そこから手が下がりながら速度がダウンスイングの最大の
        /// `descentOnsetRatio` に達したところ（切り返し）があればそこ。トップで止まっても、下ろし始めが取れる
        func topIndex(in range: Range<Int>) -> Int {
            let peakIdx = range.max { samples[$0].height < samples[$1].height }!
            let peak = samples[peakIdx].height
            let onsetSpeed = descentOnsetRatio * maxSpeed(in: peakIdx..<range.upperBound)
            return ((peakIdx + 1)..<range.upperBound).first {
                samples[$0].height < peak - 0.02 && (samples[$0].speed ?? 0) >= onsetSpeed   // 0.02 は手の揺れの分
            } ?? peakIdx
        }

        guard let up = firstHigh(from: low.upperBound + 1) else { return nil }   // 高くならない → スイングではない
        // アドレス：低い区間で最も低い高さの近くにいて、まだ動き出していない（速度がバックスイングの最大に比べて小さい）最後のサンプル。
        // 取り出しは手が横へ動くところから始まるので、高さだけでは遅れる。速度が落ち着かなければ高さだけで決める
        let rest = low.map { samples[$0].height }.min()!
        let resting = low.filter { samples[$0].height <= rest + restBand }
        let riseSpeed = maxSpeed(in: (low.upperBound + 1)..<(up + 1))
        let a = resting.last { (samples[$0].speed ?? .infinity) <= addressSpeedRatio * riseSpeed } ?? resting.last!
        let down = firstLow(from: up + 1)
        // 最初の欠測が最初の下りより前にあれば、切り返しが欠測に掛かっているかもしれない。その場合は欠測の後ろから形を読む
        let gap = ((a + 1)..<end).first { samples[$0].speed == nil }
        let gapBeforeDescent = gap.map { $0 <= (down ?? end) } ?? false

        /// フォロー（`up2` で高くなった区間）の後に手が低く戻るなら、その下りがフォローの上がりより速ければ、その高い区間は別のスイングのトップだった
        /// （素振りの直後の本番など）。上がりの速さはインパクトの次のサンプルから見る（インパクトのサンプルの速度は、そこへ到達したダウンスイングの速さ）。
        /// 切り返しが欠測で上がりの速さが取れないときは判定しない
        func isAnotherSwing(afterImpact impact: Int, up2: Int) -> Bool {
            guard let down2 = firstLow(from: up2 + 1) else { return false }
            let followRise = maxSpeed(in: (impact + 1)..<(up2 + 1))
            guard followRise > 0 else { return false }
            let lastHigh = (up2..<down2).last { samples[$0].height >= highHeight }!
            return maxSpeed(in: lastHigh..<(down2 + 1)) >= anotherSwingRatio * followRise
        }
        /// 見えている形（高い → 低い → 高い）からのトップ・インパクト・フォローの立ち上がり。形が別のスイングにまたがっていれば nil
        func fromVisibleShape() -> (top: Int, impact: Int, up2: Int)? {
            guard let s = shape(from: (gapBeforeDescent ? gap : nil) ?? (a + 1)) else { return nil }
            let top = topIndex(in: s.up..<s.down)
            let impact = lowest(in: s.down..<s.up2)
            // インパクト付近の低い区間で手が止まり（速度の最小がダウンスイングの最大の impactRestRatio 未満）、止まった後の動きが
            // 下ろしより速いか、低いまま欠測になる（30fps の本番はダウンスイングがブレて消える）なら、止まった所は次のスイングのアドレス。
            // 見えている形は「ゆっくりした素振りの下ろし → アドレス → 本番」か「フィニッシュ → 次のアドレス → 次のスイング」で、スイングではない。
            // 後方視点ではインパクト付近の手が奥へ動いて止まって見えるが、本物のフォローは下ろしより遅く、手首が隠れる欠測は肩の高さで起きるので残る
            let descentPeak = maxSpeed(in: top..<(impact + 1))
            let restSpeed = (s.down..<s.up2).filter { samples[$0].height < lowHeight }.compactMap { samples[$0].speed }.min() ?? .infinity
            if restSpeed < impactRestRatio * descentPeak {
                let after = (impact + 1)..<(s.up2 + 1)
                if maxSpeed(in: after) >= descentPeak || after.contains(where: { samples[$0].speed == nil && samples[$0 - 1].height < highHeight }) {
                    return nil
                }
            }
            if isAnotherSwing(afterImpact: impact, up2: s.up2) { return nil }
            return (top, impact, s.up2)
        }

        var estimated: Set<SwingPhase> = []
        let topIdx: Int?   // nil = 見えないので比で置く
        let impactIdx: Int
        let up2: Int       // フォローで手が高くなったところ
        if let visible = fromVisibleShape() {
            // トップ〜インパクトが見えている（欠測があってもバックスイングの途中で、その後に形が見える）
            topIdx = visible.top
            impactIdx = visible.impact
            up2 = visible.up2
        } else if gapBeforeDescent, let gap, let reappear = firstHigh(from: gap),
                  // 見えている形が無い、または別のスイングにまたがって捨てた。テークバック直後の欠測に切り返しが掛かっているなら、そこから作る。
                  // 形を捨てた後の落ち先としては、消える前に手が上がり始めていること（`takeawayRise`）を要る
                  shape(from: gap) == nil || ((a + 1)..<gap).contains(where: { samples[$0].height - samples[a].height >= takeawayRise }) {
            // 切り返しが欠測の中。インパクトは再出現から次に高くなるまでの最低点に置くが、
            // 本当のインパクトは欠測の中かもしれないので推定扱いにする
            impactIdx = lowest(in: gap..<(reappear + 1))
            estimated.insert(.impact)
            // 消える前に既に高ければトップはそこ、まだ上がり途中なら比で置く
            let before = (a + 1)..<gap
            if before.contains(where: { samples[$0].height >= highHeight }) {
                topIdx = topIndex(in: before)
            } else {
                topIdx = nil
                estimated.insert(.top)
            }
            up2 = reappear
            if isAnotherSwing(afterImpact: impactIdx, up2: up2) { return nil }
        } else {
            // 高くなったまま戻らない（振り上げただけ）、低いまま終わる（トップからアドレス位置へ戻すだけ）
            return nil
        }

        let down2 = firstLow(from: up2 + 1)
        // フィニッシュ：フォローで手が上がりきる山（そこから finishDrop 下がるまで）の高さの finishHeightRatio に最初に達したところ。
        // 肩を回るときの小さな窪みでは山を切らない
        var finishPeak = samples[up2].height
        var humpEnd = up2
        for j in up2..<(down2 ?? end) {
            if samples[j].height < finishPeak - finishDrop { break }
            finishPeak = max(finishPeak, samples[j].height)
            humpEnd = j
        }
        let finishIdx = (up2...humpEnd).first { samples[$0].height >= finishHeightRatio * finishPeak }!

        let addressTime = samples[a].time
        let impactTime = samples[impactIdx].time
        let topTime = topIdx.map { samples[$0].time } ?? (addressTime + backswingShare * (impactTime - addressTime))
        var phases = PhaseSet(address: addressTime, top: topTime, impact: impactTime, finish: samples[finishIdx].time)
        guard phases.top > phases.address, phases.impact > phases.top, phases.finish > phases.impact else { return nil }
        phases.sanitize(duration: duration)

        let candidate = SwingCandidate(
            phases: phases,
            rise: (a...finishIdx).map { samples[$0].height }.max()! - samples[a].height,
            peakSpeed: maxSpeed(in: a..<(finishIdx + 1)),
            estimated: estimated)
        return (candidate, finishIdx)
    }
}
