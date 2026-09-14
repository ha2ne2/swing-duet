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

    /// スイングの弧そのもの（形を残したい）か、ほとんど動かない部位（強く均してよい）か。
    /// 頭は起き上がりを読むのに使うが、動く量は小さいので後者に入れる
    var movesAlongTheSwing: Bool { self == .hands }

    /// 出し分けのまとまり。左右の対は別々に消したい場面が考えにくいので 1 つにする
    var group: TrailPartGroup {
        switch self {
        case .hands: return .hands
        case .head: return .head
        case .leftShoulder, .rightShoulder: return .shoulders
        case .leftHip, .rightHip: return .hips
        }
    }
}

/// 軌跡の出し分けの単位（ステージ右上の「…」で切り替える）。
/// 並びはメニューに出す順（体の上から下へ）。**数は保存に使う桁なので、並べ替えても変えない**
/// （変えると `UserDefaults` に残っている選択が別の部位にずれる）。部位を足すときは使っていない数を選ぶ
enum TrailPartGroup: Int, CaseIterable, Identifiable {
    case head = 1
    case shoulders = 2
    case hands = 0
    case hips = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .hands: return "手"
        case .head: return "頭"
        case .shoulders: return "肩"
        case .hips: return "腰"
        }
    }

    /// 隠している組を 1 つの数にまとめるための桁（`UserDefaults` に整数 1 つで持つ。
    /// 「隠す」側を立てるので、後から部位を足しても既定は表示になる）
    var bit: Int { 1 << rawValue }

    /// 隠す組の集合（数）から、描く部位を出す
    static func shownParts(hidden: Int) -> [BodyPart] {
        BodyPart.allCases.filter { hidden & $0.group.bit == 0 }
    }
}

/// 解析レート（30fps）の 1 コマ分の部位の位置（正規化座標・左下原点。見えていなければ nil）。
/// 左右は被写体から見た左右（Vision の JointName と同じ）なので、画面のどちら側に出るかは向きで入れ替わる。
/// NOTE: 辞書（`[BodyPart: CGPoint]`）で持つと switch は消えるが、JSON がキーと値の並んだ配列
///       （`["hands",[0.4,0.3],…]`）になって保存データが読みにくくなるので、名前を付けて持つ
struct JointTrailSample: Codable, Equatable {
    var time: Double
    /// 両手首の中点
    var hands: CGPoint? = nil
    /// 鼻（後方視点で顔が見えないときは目・耳で代用）。正面では起き上がりが読める
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
    /// 軌跡を作るやり方の版。増やすと、古い版で作った軌跡は比較画面が軌跡を出すときに作り直される（`ClipStore.requestTrails`）。
    /// **保存する点が変わる直し（部位の組・平滑化・人物追跡）を入れたら必ず 1 つ増やす。**
    /// 増やし忘れると、古いやり方で作った軌跡が端末に残ったままになり、見ているものが最新かどうか分からなくなる。
    /// 描き方（曲線の引き方や色）だけの変更では増やさなくてよい
    static let currentVersion = 4

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
    /// いまの位置の丸を打つとき、この時刻（動画秒）以内にコマが無ければ打たない
    static let pointTolerance = 0.1

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

    /// 時刻に最も近いコマの部位の位置（`pointTolerance` 秒以内に無ければ nil）
    func point(of part: BodyPart, at time: Double) -> CGPoint? {
        var best: (distance: Double, point: CGPoint)?
        for sample in samples {
            guard let point = sample.point(of: part) else { continue }
            let distance = abs(sample.time - time)
            if distance <= Self.pointTolerance, distance < (best?.distance ?? .infinity) { best = (distance, point) }
        }
        return best?.point
    }

    /// 部位ごとに平滑化したもの。姿勢推定の 1 コマごとの揺れを落とす。
    ///
    /// 手はスイングの弧そのものなので、形を残す 5 点の Savitzky–Golay（2 次多項式の当てはめ。移動平均と違って
    /// トップの折り返しを丸めない）を掛ける。肩と股関節はほとんど動かず、線に占めるブレの割合が大きいので、
    /// 形を残す必要がなく、より強い移動平均を掛ける（実測は docs/research/260914_0311-joint-trail-smoothing.md §12）
    /// - swingSamples: 採用スイング（アドレス〜フィニッシュ）の中のコマ数。均す窓の広さを決める
    func smoothed(swingSamples: Int) -> JointTrails {
        var result = samples
        for part in BodyPart.allCases {
            let weights: [Double] = part.movesAlongTheSwing
                ? [-3, 12, 17, 12, -3]
                : Array(repeating: 1, count: Self.bodyWindow(samples: swingSamples))
            let points = Self.convolved(samples.map { $0.point(of: part) }, weights: weights)
            for i in result.indices { result[i].set(points[i], of: part) }
        }
        return JointTrails(version: version, samples: result)
    }

    /// ほとんど動かない部位に掛ける移動平均の窓（コマ数・奇数）。
    /// **採用スイングの**コマ数に比例させて、動画の速さによらず実時間で同じくらい均す
    /// （1/8 スローは実速の 8 倍のコマ数になる。5 コマ固定では実時間で 8 分の 1 しか均せない）。
    /// 保存範囲（他の候補も含めて最大 20 秒）のコマ数で決めると、同じスイングでも前に素振りがあるかどうかで窓が倍以上変わる
    static func bodyWindow(samples: Int) -> Int {
        let width = min(max(samples / 15, 5), 21)
        return width % 2 == 0 ? width + 1 : width
    }

    /// 対称な重みの畳み込み。窓に欠けが掛かる点と端はそのまま返す（欠けを勝手に埋めない）
    private static func convolved(_ points: [CGPoint?], weights: [Double]) -> [CGPoint?] {
        let half = weights.count / 2, total = weights.reduce(0, +)
        var result = points
        guard points.count >= weights.count, total > 0 else { return result }
        for i in half..<(points.count - half) {
            let window = points[(i - half)...(i + half)].compactMap { $0 }
            guard window.count == weights.count else { continue }
            var x = 0.0, y = 0.0
            for (weight, point) in zip(weights, window) {
                x += weight * point.x
                y += weight * point.y
            }
            result[i] = CGPoint(x: x / total, y: y / total)
        }
        return result
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
