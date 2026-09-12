import Foundation

/// 長い動画に写る 1 球（ショット）：切り出す範囲と、その中で採用するスイング
struct Shot: Equatable {
    /// 切り出す範囲（動画内の秒）
    var range: ClosedRange<Double>
    /// 採用するスイング（動画内の秒）
    var swing: SwingCandidate
}

/// スイング候補の列から、1 球ずつのショット（切り出す範囲）を組む。素振りは含めない。
///
/// 練習場では「素振り → 本番 → 球を見送る → 次の球を置く」が繰り返される。候補どうしの間が短ければ同じ組（素振りと本番）とみなし、
/// 組の中で最も振り切ったものに比べて明らかに小さい候補を素振りとして捨てる（自動ティーアップでは本番が 5〜6 秒おきに続くので、
/// 同じ組でも振り切りが同程度なら両方とも本番）。組に候補が 1 つしか無いとき、それが素振りか本番かは形だけでは決められないので、
/// 他の組の本番と比べて明らかに小さければ素振りとみなして捨てる（設計は docs/design/260912_1951-in-app-slowmo-capture-and-shot-split.md §4.3）
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

        // 範囲は余白付き。動画の中に収め、前のショットと重ねない
        var shots: [Shot] = []
        for swing in kept {
            let lower = max(swing.phases.address - leadIn, shots.last?.range.upperBound ?? 0, 0)
            let upper = min(swing.phases.finish + leadOut, duration)
            guard upper > lower else { continue }
            shots.append(Shot(range: lower...upper, swing: swing))
        }
        return shots
    }
}

private extension ShotSplitter {
    /// 比べる相手の振り上げ・ピーク速度に対して両方 `practiceRatio` 未満なら素振り
    static func isPractice(_ candidate: SwingCandidate, rise: Double, peakSpeed: Double) -> Bool {
        candidate.rise < practiceRatio * rise && candidate.peakSpeed < practiceRatio * peakSpeed
    }
}
