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

/// 体に対する手の高さからスイング候補とフェーズを検出する。
/// 焼き込みスローにも対応するため、絶対時間ではなく高さの形と動画内の速度比で判断する。
/// 欠測中に推定したフェーズは estimated に記録し、候補の選択は呼び手に任せる。
/// 検出規則としきい値の根拠は docs/design/260910_0236-hand-height-phase-detection.md。
enum SwingDetector {

    /// これ未満なら手が「低い」（アドレス・インパクト）。実測はアドレス −0.2〜0.1
    private static let lowHeight = 0.3
    /// これ以上なら手が「高い」（トップ・フィニッシュ）。実測は 0.7〜1.9。
    /// 撮影中の「手が動いている」の判定（`LiveDetector`）も同じ高さを使うので private にしない
    static let highHeight = 0.5
    /// 手首が見えない時間がこれ以上なら欠測として扱う（解析は 30fps なので 6 フレーム。欠測明けのサンプルは速度が nil）
    private static let gapDuration = 0.2
    /// アドレス：低い区間で最も低い高さからこの範囲内にいるサンプルのうち、
    /// 速度がバックスイングの最大の `addressSpeedRatio` 以下（まだ動き出していない）である最後のもの
    private static let restBand = 0.1
    private static let addressSpeedRatio = 0.15
    /// トップ（切り返し）：最も高い点の後、高さが下がりながら速度がダウンスイングの最大のこの割合に達したところ
    private static let descentOnsetRatio = 0.3
    /// フィニッシュ：フォローで手が最も高くなる（そこから `finishDrop` 下がるまでの山の）高さに、
    /// 体の大きさ単位でこれだけ近づいた最初のところ（＝振り切った位置に着いた瞬間）
    /// NOTE: 割合（山の高さの 90%）だと、正面視点は手が体の前を横切って高さの上がり方が緩く、振り切る前
    ///       （実サンプルで 0.4〜0.5 秒手前）を拾う。山の頂点そのものは、振り切った姿勢のまま手が僅かに
    ///       上へ流れる分だけ 0.4 秒遅れる。速度（手が止まったところ）は、正面では振り切った後も手が横へ
    ///       流れて落ちず、後方ではすぐ止まるので、同じ比が両方の視点には効かない
    private static let finishBand = 0.05
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

        guard !candidates.isEmpty else { return [] }
        // 採点：振り上げの大きさとピーク速度（候補内の最大で正規化）。同程度なら後のスイング（本番は素振りの後）
        let maxRise = max(candidates.map(\.rise).max()!, 0.001)
        let maxPeak = max(candidates.map(\.peakSpeed).max()!, 0.001)
        for i in candidates.indices {
            let order = candidates.count > 1 ? Double(i) / Double(candidates.count - 1) : 0
            candidates[i].score = 0.5 * candidates[i].rise / maxRise + 0.5 * candidates[i].peakSpeed / maxPeak + 0.03 * order
        }
        return candidates
    }

    // MARK: - 手の系列

    /// 手首が見えたフレームの、体の大きさ単位の高さと速度。速度は移動平均（窓 5）で平滑化する
    static func handSamples(track: PoseTrack) -> [HandSample] {
        // 体の大きさが取れた ＝ 腰と首が同時に取れたコマが 1 つ以上ある（`PoseTrack.torsoHeight` は正のときだけ値を返す）ので、
        // 腰の高さの初期値も必ず取れる。腰は毎フレーム取れるとは限らないので、直前に取れた値を使う（スイング中ほとんど動かない）
        guard let torso = track.torsoHeight,
              var rootY = track.frames.first(where: { $0.root != nil })?.root.map({ Double($0.y) }) else { return [] }
        var samples: [HandSample] = []
        var last: (time: Double, point: CGPoint)? = nil
        for frame in track.frames {
            if let root = frame.root { rootY = Double(root.y) }
            guard let wrist = frame.wrist else { continue }
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
        let hand = HandSeries(samples: samples)
        guard let up = hand.firstHigh(from: low.upperBound + 1) else { return nil }   // 高くならない → スイングではない
        let address = hand.addressIndex(in: low, risingTo: up)
        // 最初の欠測が最初の下りより前にあれば、切り返しが欠測に掛かっているかもしれない。その場合は欠測の後ろから形を読む
        let afterGap = (address + 1..<hand.endIndex).first { samples[$0].speed == nil }
        let gapBeforeDescent = afterGap.map { $0 <= (hand.firstLow(from: up + 1) ?? hand.endIndex) } ?? false

        var estimated: Set<SwingPhase> = []
        let top: Int?      // nil = 見えないので比で置く
        let impact: Int
        let follow: Int    // フォローで手が高くなったところ

        if let visible = hand.visibleSwing(from: (gapBeforeDescent ? afterGap : nil) ?? (address + 1)) {
            // トップ〜インパクトが見えている（欠測があってもバックスイングの途中で、その後に形が見える）
            (top, impact, follow) = visible
        } else if gapBeforeDescent, let afterGap, let followStart = hand.firstHigh(from: afterGap),
                  // 見えている形が無い、または別のスイングにまたがって捨てた。テークバック直後の欠測に切り返しが掛かっているなら、そこから作る。
                  // 形を捨てた後の落ち先としては、消える前に手が上がり始めていること（`takeawayRise`）を要る
                  hand.shape(from: afterGap) == nil || hand.rises(from: address, before: afterGap, by: takeawayRise) {
            // 切り返しが欠測の中。インパクトは再出現から次に高くなるまでの最低点に置くが、
            // 本当のインパクトは欠測の中かもしれないので推定扱いにする
            impact = hand.lowest(in: afterGap..<(followStart + 1))
            estimated.insert(.impact)
            // 消える前に既に高ければトップはそこ、まだ上がり途中なら比で置く
            let backswing = (address + 1)..<afterGap
            if backswing.contains(where: { samples[$0].height >= highHeight }) {
                top = hand.topIndex(in: backswing)
            } else {
                top = nil
                estimated.insert(.top)
            }
            follow = followStart
            if hand.isAnotherSwing(afterImpact: impact, follow: follow) { return nil }
        } else {
            // 高くなったまま戻らない（振り上げただけ）、低いまま終わる（トップからアドレス位置へ戻すだけ）
            return nil
        }

        let finish = hand.finishIndex(after: follow)
        let addressTime = samples[address].time
        let impactTime = samples[impact].time
        var phases = PhaseSet(
            address: addressTime,
            top: top.map { samples[$0].time } ?? (addressTime + backswingShare * (impactTime - addressTime)),
            impact: impactTime,
            finish: samples[finish].time)
        guard phases.top > phases.address, phases.impact > phases.top, phases.finish > phases.impact else { return nil }
        phases.sanitize(duration: duration)

        let candidate = SwingCandidate(
            phases: phases,
            rise: (address...finish).map { samples[$0].height }.max()! - samples[address].height,
            peakSpeed: hand.maxSpeed(in: address..<(finish + 1)),
            estimated: estimated)
        return (candidate, finish)
    }

    /// 手の系列を添字で読む。スイング 1 回の形を読む間に同じ列を何度も見るので、その読み方をここにまとめる。
    ///
    /// NOTE: 範囲を取る関数は、空でない範囲を渡すことが呼び出し側で決まっている（見つけた添字の間、または
    ///       要素があると確認した範囲）ので、`min` / `max` の強制アンラップは安全
    private struct HandSeries {
        let samples: [HandSample]

        var endIndex: Int { samples.count }

        /// i 以降で最初に手が高くなる（トップ・フィニッシュの高さ）ところ
        func firstHigh(from i: Int) -> Int? { (i..<endIndex).first { samples[$0].height >= highHeight } }

        /// i 以降で最初に手が低くなる（アドレス・インパクトの高さ）ところ
        func firstLow(from i: Int) -> Int? { (i..<endIndex).first { samples[$0].height < lowHeight } }

        /// `start` 以降で最初に見える「高い → 低い → 高い」の形
        func shape(from start: Int) -> (up: Int, down: Int, up2: Int)? {
            guard let up = firstHigh(from: start), let down = firstLow(from: up + 1),
                  let up2 = firstHigh(from: down + 1) else { return nil }
            return (up, down, up2)
        }

        func maxSpeed(in range: Range<Int>) -> Double { range.compactMap { samples[$0].speed }.max() ?? 0 }

        /// 範囲の中で手が最も低いところ
        func lowest(in range: Range<Int>) -> Int { range.min { samples[$0].height < samples[$1].height }! }

        /// アドレス：低い区間で最も低い高さの近く（`restBand`）にいて、まだ動き出していない（速度が振り上げの最大に比べて
        /// `addressSpeedRatio` 以下）最後のサンプル。取り出しは手が横へ動くところから始まるので高さだけでは遅れる。
        /// 速度が落ち着かなければ高さだけで決める
        func addressIndex(in low: ClosedRange<Int>, risingTo up: Int) -> Int {
            let rest = low.map { samples[$0].height }.min()!
            let resting = low.filter { samples[$0].height <= rest + restBand }
            let backswingPeakSpeed = maxSpeed(in: (low.upperBound + 1)..<(up + 1))
            return resting.last { (samples[$0].speed ?? .infinity) <= addressSpeedRatio * backswingPeakSpeed } ?? resting.last!
        }

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

        /// 見えている形（高い → 低い → 高い）から読んだトップ・インパクト・フォローの立ち上がり。
        /// 形が別のスイングにまたがっていれば nil
        func visibleSwing(from start: Int) -> (top: Int, impact: Int, follow: Int)? {
            guard let s = shape(from: start) else { return nil }
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
            if isAnotherSwing(afterImpact: impact, follow: s.up2) { return nil }
            return (top, impact, s.up2)
        }

        /// フォロー（`follow` で高くなった区間）の後に手が低く戻るなら、その下りがフォローの上がりより速ければ、
        /// その高い区間は別のスイングのトップだった（素振りの直後の本番など）。上がりの速さはインパクトの次のサンプルから見る
        /// （インパクトのサンプルの速度は、そこへ到達したダウンスイングの速さ）。
        /// 切り返しが欠測で上がりの速さが取れないときは判定しない
        func isAnotherSwing(afterImpact impact: Int, follow: Int) -> Bool {
            guard let down2 = firstLow(from: follow + 1) else { return false }
            let followRise = maxSpeed(in: (impact + 1)..<(follow + 1))
            guard followRise > 0 else { return false }
            let lastHigh = (follow..<down2).last { samples[$0].height >= highHeight }!
            return maxSpeed(in: lastHigh..<(down2 + 1)) >= anotherSwingRatio * followRise
        }

        /// フィニッシュ：フォローで手が上がりきる山（そこから `finishDrop` 下がるまで）の高さに `finishBand` まで
        /// 近づいた最初のところ。肩を回るときの小さな窪みでは山を切らない
        func finishIndex(after follow: Int) -> Int {
            var peak = samples[follow].height
            var humpEnd = follow
            for j in follow..<(firstLow(from: follow + 1) ?? endIndex) {
                if samples[j].height < peak - finishDrop { break }
                peak = max(peak, samples[j].height)
                humpEnd = j
            }
            return (follow...humpEnd).first { samples[$0].height >= peak - finishBand }!
        }

        /// `from` の高さから `by` 以上高くなるサンプルが `before` より前にあるか
        func rises(from address: Int, before limit: Int, by rise: Double) -> Bool {
            ((address + 1)..<limit).contains { samples[$0].height - samples[address].height >= rise }
        }
    }
}
