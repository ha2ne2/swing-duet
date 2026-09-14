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
    /// 欠測をまたいでつなぐときに、1 コマぶん（`maxJump`）の何倍までの移動を許すか
    static let bridgedJumpFactor = 2.0
    /// 同じく、またいだ区間の速さが前後で見えていた速さの何倍までなら釣り合っているとみなすか。
    /// 隠れている間に速くなることはあるが、止まっている誤検出へつなぐのは防ぐ
    /// （実測では、正しくつながる例が 1.1 倍、貼り付いた誤検出へつながる例が 26.8 倍）
    static let bridgedSpeedFactor = 3.0
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

    /// 隣り合う 2 つの観測を 1 本の線としてつないでよいか（`points[index - 1]` と `points[index]`）。
    ///
    /// 1 コマぶんの移動（`maxJump`）までは素通し。欠測をまたいだ大きい移動は、
    /// **またいだ区間の速さが前後で見えていた速さと釣り合っているときだけ**つなぐ。
    /// 後方視点のフォローでは手が数コマ体に隠れるので、その間もつないで線を伸ばしたい。
    /// 一方、別の場所に貼り付いた誤検出へつなぐと、止まっている点へ画面を横切る線が伸びてしまう
    /// （実測は docs/research/260915_0624-hand-trail-occlusion.md）
    static func connects(_ points: [TrailPoint], at index: Int) -> Bool {
        let (a, b) = (points[index - 1], points[index])
        let elapsed = b.time - a.time, moved = a.point.distance(to: b.point)
        guard elapsed > 0, elapsed <= maxGap else { return false }
        if moved <= maxJump { return true }
        guard moved <= maxJump * bridgedJumpFactor else { return false }
        func speed(endingAt i: Int) -> Double {
            guard i > 0, i < points.count else { return 0 }
            return points[i - 1].point.distance(to: points[i].point) / (points[i].time - points[i - 1].time)
        }
        let nearby = max(speed(endingAt: index - 1), speed(endingAt: index + 1))
        return moved / elapsed <= nearby * bridgedSpeedFactor
    }

    /// 前後のコマがどちらも欠測している、ぽつんと 1 コマだけの観測か。
    /// 部位は連続して動くので、隣に仲間のいない点は誤検出のことが多い（実測でスイング区間の観測の 0.16%）。
    /// 後方視点で手が体に隠れる間に 1 コマだけ現れる誤検出が、線を逆向きに伸ばしていた
    /// （docs/research/260915_0624-hand-trail-occlusion.md）。
    /// 保存範囲の端は「隣が無い」だけで欠測ではないので、孤立とはみなさない
    private func isLoneObservation(of part: BodyPart, at index: Int) -> Bool {
        index > 0 && index < samples.count - 1
            && samples[index - 1].point(of: part) == nil && samples[index + 1].point(of: part) == nil
    }

    /// 線に使う観測（範囲内・見えていて・孤立していない点）を時刻順に
    private func observations(of part: BodyPart, in range: ClosedRange<Double>) -> [TrailPoint] {
        samples.enumerated().compactMap { index, sample in
            guard range.contains(sample.time), let point = sample.point(of: part),
                  !isLoneObservation(of: part, at: index) else { return nil }
            return TrailPoint(time: sample.time, point: point)
        }
    }

    /// 部位の連続した点列。`range` の中の観測を時刻順に並べ、`connects` が繋がらないと判断したところで切る。
    /// 1 点だけの線は返さない
    func strokes(of part: BodyPart, in range: ClosedRange<Double>) -> [[TrailPoint]] {
        let seen = observations(of: part, in: range)
        var result: [[TrailPoint]] = []
        var current: [TrailPoint] = []
        for index in seen.indices {
            if index > 0, !Self.connects(seen, at: index) {
                if current.count >= 2 { result.append(current) }
                current = []
            }
            current.append(seen[index])
        }
        if current.count >= 2 { result.append(current) }
        return result
    }

    /// 線の上の、その時刻の位置。**コマとコマの間は前後から補間する**。
    /// 部位が体に隠れている間も線と丸が一定の速さで進むようにするため（止めると、見えた瞬間に一気に伸びる）。
    /// 時刻を含む線が無ければ、端がいちばん近い線の端（`pointTolerance` 秒以内）を返す。それも無ければ nil
    /// （線の無いところに丸だけを浮かせない）
    static func position(on strokes: [[TrailPoint]], at time: Double) -> CGPoint? {
        var best: (gap: Double, point: CGPoint)?
        for stroke in strokes {
            guard let first = stroke.first, let last = stroke.last else { continue }
            let gap = max(first.time - time, time - last.time, 0)   // 線の外へはみ出した秒数（線の中なら 0）
            guard gap <= pointTolerance, gap < best?.gap ?? .infinity else { continue }
            best = (gap, gap > 0 ? (time < first.time ? first.point : last.point) : interpolated(stroke, at: time))
        }
        return best?.point
    }

    /// 線の中のその時刻の位置（前後のコマから時刻の比で取る）
    private static func interpolated(_ stroke: [TrailPoint], at time: Double) -> CGPoint {
        guard let index = stroke.firstIndex(where: { $0.time >= time }), index > 0 else { return stroke[0].point }
        let (a, b) = (stroke[index - 1], stroke[index])
        let ratio = (time - a.time) / (b.time - a.time)
        return CGPoint(x: a.point.x + (b.point.x - a.point.x) * ratio,
                       y: a.point.y + (b.point.y - a.point.y) * ratio)
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
