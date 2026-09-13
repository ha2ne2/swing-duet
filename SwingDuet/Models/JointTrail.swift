import Foundation
import CoreGraphics

/// 軌跡を描く体の部位。**並びが描く順**（股関節を下に、手を一番上に重ねる）。
/// 肩と股関節を左右に分けているのは、1 本の線（首・腰の中心）では回旋が消えるため
/// （実測は docs/research/260913_2016-joint-choice-for-trails.md）
enum BodyPart: CaseIterable {
    case leftHip
    case rightHip
    case leftShoulder
    case rightShoulder
    case head
    case hands
}

/// 解析レート（30fps）の 1 コマ分の部位の位置（正規化座標・左下原点。見えていなければ nil）。
/// 左右は被写体から見た左右（Vision の JointName と同じ）なので、画面のどちら側に出るかは向きで入れ替わる。
/// NOTE: 辞書（`[BodyPart: CGPoint]`）で持つと switch は消えるが、JSON がキーと値の並んだ配列
///       （`["hands",[0.4,0.3],…]`）になって保存データが読みにくくなるので、名前を付けて持つ
struct JointTrailSample: Codable, Equatable {
    var time: Double
    /// 両手首の中点
    var hands: CGPoint? = nil
    /// 鼻（後方視点で顔が見えないときは目・耳で代用）
    var head: CGPoint? = nil
    var leftShoulder: CGPoint? = nil
    var rightShoulder: CGPoint? = nil
    var leftHip: CGPoint? = nil
    var rightHip: CGPoint? = nil

    func point(of part: BodyPart) -> CGPoint? {
        switch part {
        case .leftHip: return leftHip
        case .rightHip: return rightHip
        case .leftShoulder: return leftShoulder
        case .rightShoulder: return rightShoulder
        case .head: return head
        case .hands: return hands
        }
    }

    mutating func set(_ point: CGPoint?, of part: BodyPart) {
        switch part {
        case .leftHip: leftHip = point
        case .rightHip: rightHip = point
        case .leftShoulder: leftShoulder = point
        case .rightShoulder: rightShoulder = point
        case .head: head = point
        case .hands: hands = point
        }
    }
}

/// 軌跡の 1 点（描画用。時刻はその動画の秒）
struct TrailPoint: Equatable {
    var time: Double
    var point: CGPoint
}

/// 部位ごとの軌跡。解析時に採用スイングの周り（`sampleRange`）を平滑化して保存し、比較画面で動画に重ねて描く。
/// 動画に対する事実なので、フェーズを手で直しても変わらない（どの範囲を描くかは描くときのフェーズで決める）
struct JointTrails: Codable, Equatable {
    /// 部位の組の版。増やすと、古い版で作った軌跡は比較画面を開いたときに作り直される
    /// （版 1: 首と腰の中心 → 両肩と両股関節に替えた）
    static let currentVersion = 1

    var version = JointTrails.currentVersion
    var samples: [JointTrailSample]

    /// 欠けがこれ（動画秒）より長く続いたら線を切る（それより短い欠けは前後の点を直接つなぐ）
    static let maxGap = 0.3
    /// 隣のコマからこれ（正規化距離）より飛んだら誤検出として線を切る。実速 30fps のダウンスイングでも 1 コマの移動は 0.2 未満
    static let maxJump = 0.25
    /// 保存する範囲の、スイングの前後の余白（秒）
    static let margin = 1.0
    /// 保存する範囲の上限（秒）。長回しの動画で他の候補まで含めると JSON が肥大するので、収まるときだけ候補全体を含める
    static let maxSpan = 20.0

    /// 保存する範囲：採用スイングの前後 `margin` 秒。フェーズ調整で選び直せる他の候補も含めて `maxSpan` に収まるならそこまで広げる
    static func sampleRange(chosen: PhaseSet, candidates: [PhaseSet]) -> ClosedRange<Double> {
        let lower = min(chosen.address, candidates.map(\.address).min() ?? chosen.address) - margin
        let upper = max(chosen.finish, candidates.map(\.finish).max() ?? chosen.finish) + margin
        return upper - lower <= maxSpan ? lower...upper : (chosen.address - margin)...(chosen.finish + margin)
    }

    /// いまの部位の組で作られたものか（古ければ作り直す）
    var isCurrent: Bool { version >= Self.currentVersion }

    /// 部位の連続した点列。`range` の中の見えていた点を時刻順に並べ、長い欠け（`maxGap`）と飛び（`maxJump`）で切る。1 点だけの線は返さない
    func strokes(of part: BodyPart, in range: ClosedRange<Double>) -> [[TrailPoint]] {
        var result: [[TrailPoint]] = []
        var current: [TrailPoint] = []
        func flush() {
            if current.count >= 2 { result.append(current) }
            current = []
        }
        for sample in samples where range.contains(sample.time) {
            guard let point = sample.point(of: part) else { continue }
            if let last = current.last, sample.time - last.time > Self.maxGap || point.distance(to: last.point) > Self.maxJump {
                flush()
            }
            current.append(TrailPoint(time: sample.time, point: point))
        }
        flush()
        return result
    }

    /// 時刻に最も近いコマの部位の位置（`tolerance` 秒以内に無ければ nil）
    func point(of part: BodyPart, at time: Double, tolerance: Double = 0.1) -> CGPoint? {
        var best: (distance: Double, point: CGPoint)?
        for sample in samples {
            guard let point = sample.point(of: part) else { continue }
            let distance = abs(sample.time - time)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (distance, point) }
        }
        return best?.point
    }

    /// 5 点の Savitzky–Golay（2 次多項式の当てはめ）で各部位を平滑化したもの。姿勢推定の 1 コマごとの揺れを半分ほどに抑え、
    /// 移動平均と違ってトップの折り返しの形を丸めない。窓に欠けが掛かる点と端の 2 点はそのまま
    func smoothed() -> JointTrails {
        let weights: [Double] = [-3, 12, 17, 12, -3]
        let total = weights.reduce(0, +)
        guard samples.count >= weights.count else { return self }
        var result = samples
        for part in BodyPart.allCases {
            let points = samples.map { $0.point(of: part) }
            for i in 2..<(points.count - 2) {
                let window = points[(i - 2)...(i + 2)].compactMap { $0 }
                guard window.count == weights.count else { continue }
                var x = 0.0, y = 0.0
                for (weight, point) in zip(weights, window) {
                    x += weight * point.x
                    y += weight * point.y
                }
                result[i].set(CGPoint(x: x / total, y: y / total), of: part)
            }
        }
        return JointTrails(version: version, samples: result)
    }
}

extension JointTrails {
    private enum CodingKeys: String, CodingKey {
        case version, samples
    }

    /// 版を書く前の保存データ（版 0。首と腰の中心で作った軌跡）も読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        samples = try c.decode([JointTrailSample].self, forKey: .samples)
    }
}
