import Foundation

/// 長い動画に写る 1 球（ショット）：切り出す範囲と、その中で採用するスイング
struct Shot: Equatable {
    /// 切り出す範囲（動画内の秒）
    var range: ClosedRange<Double>
    /// 採用するスイング（動画内の秒）
    var swing: SwingCandidate
}

/// 候補を時間の近い組に分け、振り上げと速度が小さい素振りを除いて切り出し範囲を決める。
/// 同じ組でも振り切りが同程度なら複数球を残す。単独候補は他の組と比較する。
/// 根拠は docs/design/260912_1951-in-app-slowmo-capture-and-shot-split.md §4.3。
enum ShotSplitter {
    /// 候補のフィニッシュから次の候補のアドレスまでがこれ以内なら同じ組（秒）。素振りと本番の間は 2〜4 秒
    static let groupGap = 6.0
    /// 切り出す範囲の余白（秒）。アドレスの前と、フィニッシュの後
    static let leadIn = 1.5
    static let leadOut = 1.5
    /// 比べる相手（同じ組の最も振り切った候補、または他の組の代表の中央値）に対して振り上げ・ピーク速度ともこの割合未満なら素振りとみなす
    static let practiceRatio = 0.6

    static func shots(candidates: [SwingCandidate], duration: Double) -> [Shot] {
        var groups: [[SwingCandidate]] = []
        for candidate in candidates.sorted(by: { $0.phases.address < $1.phases.address }) {
            if let last = groups.last?.last, candidate.phases.address - last.phases.finish <= groupGap {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        // 組の中では、最も振り切った候補（採点は候補の列の中での相対値。同程度なら後の候補）に比べて明らかに小さいものだけを素振りとして捨てる
        var kept = groups.flatMap { group -> [SwingCandidate] in
            guard let top = group.max(by: { $0.score < $1.score }) else { return [] }
            return group.filter { !isPractice($0, rise: top.rise, peakSpeed: top.peakSpeed) }
        }

        // 素振りだけの組を捨てる（比べる相手が要るので 2 つ以上のとき。残った候補の中央値と比べる）
        if kept.count >= 2, let rise = kept.map(\.rise).median, let peak = kept.map(\.peakSpeed).median {
            kept.removeAll { isPractice($0, rise: rise, peakSpeed: peak) }
        }

        var shots: [Shot] = []
        for swing in kept {
            guard let range = range(of: swing, after: shots.last?.range.upperBound ?? 0, duration: duration) else { continue }
            shots.append(Shot(range: range, swing: swing))
        }
        return shots
    }
}

extension ShotSplitter {
    /// 比べる相手の振り上げ・ピーク速度に対して両方 `practiceRatio` 未満なら素振り。撮影中の判定（`LiveShotJudge`）も同じ規則を使う
    static func isPractice(_ candidate: SwingCandidate, rise: Double, peakSpeed: Double) -> Bool {
        candidate.rise < practiceRatio * rise && candidate.peakSpeed < practiceRatio * peakSpeed
    }

    /// 候補を切り出す範囲：アドレスの前とフィニッシュの後に余白（`leadIn` / `leadOut`）を足し、動画の頭から出ないようにする。
    /// 撮影中（`LiveShotJudge`・`LiveDetector`）も同じ規則で切り出すので、余白の取り方はここだけに置く。
    /// - after: 前のショットの終わり（範囲を重ねない）
    /// - duration: 動画の長さ（末尾を越えない）。撮影中はまだ長さが決まっていないので nil
    /// - Returns: 余白を詰めた結果 1 コマも残らなければ nil
    static func range(of candidate: SwingCandidate, after previousEnd: Double = 0, duration: Double? = nil) -> ClosedRange<Double>? {
        let lower = max(candidate.phases.address - leadIn, previousEnd, 0)
        let upper = duration.map { min(candidate.phases.finish + leadOut, $0) } ?? (candidate.phases.finish + leadOut)
        return upper > lower ? lower...upper : nil
    }
}
