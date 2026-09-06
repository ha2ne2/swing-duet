import Foundation
import CoreGraphics

/// 手首速度の 1 サンプル
struct SpeedSample {
    var time: Double
    /// 平滑化した速度（正規化距離/秒）
    var speed: Double
    /// その時刻の手首位置
    var point: CGPoint
}

/// 1 回のスイング候補（採点の内訳付き）
struct SwingCandidate {
    var phases: PhaseSet
    /// 区間内の最大手首速度
    var peakSpeed: Double
    /// アドレス位置からトップまでの手首の移動量（正規化距離）
    var backswingSpan: Double
    /// インパクトからフィニッシュまでの手首の移動量（正規化距離）
    var followSpan: Double
    /// トップからインパクトの間で手首を見失っていた最長時間（秒）
    var downswingGap: Double
    /// 「振り切り度」。大きいほど本番スイングらしい（候補の中での相対値。最良の候補が約 1.0）
    var score: Double = 0

    /// 手の移動量（バックスイング + フォロー）
    var travel: Double { backswingSpan + followSpan }

    /// 切り返し〜インパクトがブレで観測できていない。30fps では速い動きで手首を見失いやすく、
    /// そのときのトップ・インパクトは欠測の両端に置かれるので位置が粗い（手動確認を促す）
    var downswingUnobserved: Bool { downswingGap >= 0.2 }
}

/// 手首の追跡結果からスイング区間とフェーズを検出する。
///
/// 1 本の動画に素振りなど複数のスイングが写っていることを前提に、動作区間ごとにフェーズを求めて採点する
/// （最も「振り切っている」候補を採用するのは呼び出し側。候補はすべて返し、ユーザーが選び直せる）。
///
/// 各スイングのフェーズは、手首とアドレス位置との距離の形で決める：
/// - アドレス: 動作区間の手前で静止が続く点
/// - トップ: 手首がアドレス位置から最も離れた点（折り返し）
/// - インパクト: トップの後、手首がアドレス位置に最も近づく点（通過）
/// - フィニッシュ: インパクトの後に静止が続く点
/// 速度の最大値をインパクトとみなさないのは、30fps ではインパクト前後がブレて手首を見失うことが多く、
/// 観測できた最大速度がフォロー側にずれるため。
enum SwingDetector {

    /// スイング候補を作り、採点する（時系列順）。スイングが見つからなければ空
    static func detect(track: PoseTrack, duration: Double) -> [SwingCandidate] {
        let samples = speedSeries(track: track)
        guard samples.count >= 8, let maxSpeed = samples.map(\.speed).max(), maxSpeed > 0 else { return [] }

        let segments = motionSegments(samples, threshold: 0.20 * maxSpeed)
        var candidates: [SwingCandidate] = []
        for (i, segment) in segments.enumerated() {
            // アドレス・フィニッシュを探してよい範囲。隣の区間がある側はそのサンプル時刻まで、無い側は動画の端まで
            let lowerBound = i > 0 ? segments[i - 1].end + 1 : 0
            let upperBound = i + 1 < segments.count ? segments[i + 1].start - 1 : samples.count - 1
            let lowerTime = i > 0 ? samples[lowerBound].time : 0
            let upperTime = i + 1 < segments.count ? samples[upperBound].time : duration
            if let candidate = swingCandidate(
                in: segment, samples: samples, searchRange: lowerBound...upperBound, timeBounds: lowerTime...upperTime,
                stillThreshold: 0.10 * maxSpeed, duration: duration) {
                candidates.append(candidate)
            }
        }

        // 採点：手の移動量とピーク速度（候補内の最大で正規化）。同程度なら後のスイング（本番は素振りの後）
        let maxTravel = candidates.map(\.travel).max() ?? 1
        let maxPeak = candidates.map(\.peakSpeed).max() ?? 1
        for i in candidates.indices {
            let order = candidates.count > 1 ? Double(i) / Double(candidates.count - 1) : 0
            candidates[i].score = 0.5 * candidates[i].travel / maxTravel + 0.5 * candidates[i].peakSpeed / maxPeak + 0.03 * order
        }
        return candidates
    }

    // MARK: - 速度系列

    /// 手首速度の系列（単位: 正規化距離/秒）。移動平均（窓 5）で平滑化する。
    /// 検出できないフレームは飛ばし、直前の検出から 0.25 秒以上あいたサンプル（ブレで見失った直後）の速度は作らない
    static func speedSeries(track: PoseTrack) -> [SpeedSample] {
        var samples: [SpeedSample] = []
        var last: (time: Double, point: CGPoint)? = nil
        for (t, p) in zip(track.times, track.points) {
            guard let p else { continue }
            if let last, t - last.time > 0, t - last.time < 0.25 {
                samples.append(SpeedSample(time: t, speed: Double(p.distance(to: last.point)) / (t - last.time), point: p))
            }
            last = (t, p)
        }

        let raw = samples.map(\.speed)
        let half = 2
        for i in raw.indices {
            let window = raw[max(0, i - half)...min(raw.count - 1, i + half)]
            samples[i].speed = window.reduce(0, +) / Double(window.count)
        }
        return samples
    }

    // MARK: - 動作区間

    /// 速度サンプルの添字で表した動作区間（両端を含む）
    struct Segment {
        var start: Int
        var end: Int
    }

    /// 速度が threshold 以上の区間を「1 回のスイング動作」としてまとめる。
    /// 切り返しの一瞬の減速で分断しないよう、低速サンプルの連なりが pauseMax 秒未満なら同じ区間に含める。
    /// 追跡が途切れた時間帯（速い動きでブレて検出できない）には低速サンプルが無いので、自然に同じ区間になる。
    static func motionSegments(_ samples: [SpeedSample], threshold: Double, pauseMax: Double = 0.6) -> [Segment] {
        var segments: [Segment] = []
        var pauseStart: Int? = nil   // 直近の区間の後に続いている低速サンプルの先頭
        for i in samples.indices {
            guard samples[i].speed >= threshold else {
                if !segments.isEmpty, pauseStart == nil { pauseStart = i }
                continue
            }
            // 低速サンプルの連なりの長さ（先頭から、動きが戻ったこのサンプルまで）
            let pause = pauseStart.map { samples[i].time - samples[$0].time } ?? 0
            if segments.isEmpty || pause >= pauseMax {
                segments.append(Segment(start: i, end: i))
            } else {
                segments[segments.count - 1].end = i
            }
            pauseStart = nil
        }
        return segments
    }

    // MARK: - 区間のフェーズ

    /// 動作区間からスイング候補を作る。searchRange / timeBounds はアドレス・フィニッシュを探してよい範囲（隣の区間に踏み込まない）。
    /// スイングと呼べる動きが無ければ nil
    private static func swingCandidate(
        in segment: Segment,
        samples: [SpeedSample],
        searchRange: ClosedRange<Int>,
        timeBounds: ClosedRange<Double>,
        stillThreshold: Double,
        duration: Double
    ) -> SwingCandidate? {
        let minBackswingSpan = 0.08   // これより小さい動きはワッグルや揺れ

        // --- アドレス：区間の手前で静止が 0.15 秒続く点（無ければ区間の先頭） ---
        let addressIdx = stride(from: segment.start - 1, through: searchRange.lowerBound, by: -1)
            .first { isStill(samples, from: $0, toward: searchRange.lowerBound, window: 0.15, below: stillThreshold) }
            ?? segment.start
        let addressPoint = samples[addressIdx].point
        func distance(_ i: Int) -> Double { Double(samples[i].point.distance(to: addressPoint)) }

        // --- トップとインパクト：アドレス位置から離れて（トップ）、戻って最も近づき（インパクト）、また離れていく ---
        var topIdx = segment.start
        var topDistance = 0.0
        var impactIdx: Int? = nil
        var impactDistance = Double.infinity
        for i in segment.start...segment.end {
            let d = distance(i)
            if impactIdx == nil {
                if d > topDistance {
                    topDistance = d
                    topIdx = i
                } else if topDistance >= minBackswingSpan && d < 0.5 * topDistance {
                    impactIdx = i          // 折り返して半分以上戻った → ここからインパクトを探す
                    impactDistance = d
                }
            } else if d < impactDistance {
                impactDistance = d
                impactIdx = i
            } else if d > impactDistance + 0.5 * topDistance {
                break                      // フォローで再び離れ始めた
            }
        }
        guard let impactIdx else { return nil }

        // --- フィニッシュ：インパクトの後で静止が 0.2 秒続く点（無ければ区間の末尾） ---
        let finishIdx = stride(from: impactIdx + 1, through: searchRange.upperBound, by: 1)
            .first { isStill(samples, from: $0, toward: searchRange.upperBound, window: 0.2, below: stillThreshold) }
            ?? segment.end

        var phases = PhaseSet(
            address: max(timeBounds.lowerBound, samples[addressIdx].time - 0.1),
            top: samples[topIdx].time,
            impact: samples[impactIdx].time,
            finish: min(timeBounds.upperBound, samples[finishIdx].time + 0.2))
        guard phases.top > phases.address, phases.impact > phases.top, phases.finish > phases.impact else { return nil }
        phases.sanitize(duration: duration)

        return SwingCandidate(
            phases: phases,
            peakSpeed: samples[segment.start...segment.end].map(\.speed).max() ?? 0,
            backswingSpan: topDistance,
            followSpan: Double(samples[finishIdx].point.distance(to: samples[impactIdx].point)),
            downswingGap: stride(from: topIdx, to: impactIdx, by: 1).map { samples[$0 + 1].time - samples[$0].time }.max() ?? 0)
    }

    /// idx から bound の方向へ window 秒にわたって速度が threshold 未満（静止）が続いているか。bound を越えては見ない
    private static func isStill(
        _ samples: [SpeedSample], from idx: Int, toward bound: Int, window: Double, below threshold: Double
    ) -> Bool {
        stride(from: idx, through: bound, by: bound >= idx ? 1 : -1)
            .prefix { abs(samples[$0].time - samples[idx].time) <= window }
            .allSatisfy { samples[$0].speed < threshold }
    }
}
