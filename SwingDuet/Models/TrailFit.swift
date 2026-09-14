import Foundation
import CoreGraphics

/// 各部位のスイング区間を、区間全体に当てはめた 6 制御点の 3 次スプラインで表示する。
/// 保存点やフェーズ検出は変えない（表示だけの派生データ）。
/// 根拠は docs/research/260915_0527-body-trail-fitting.md（手だけだった時点の検証は 260915_0328-hand-fit-video-check.md）。
///
/// 測定点を制御点にする描画（`JointTrailOverlay.curve`）は 1 点のブレがそのまま線に出るが、
/// 区間全体への当てはめなら、単発の誤検出は多数の点に埋もれて線が引きずられない。
/// 効きは手より肩・股関節の方が大きい。動く量が小さいぶん、同じ距離を進む間に手の 2.6〜5 倍曲がっているため。
///
/// 入力は保存済みの軌跡（`JointTrails.smoothed` を通った後の点）。平滑化前の点に当てはめると肩・股関節はかえって荒れるので、
/// これは平滑化の置き換えではない
struct TrailFit {
    /// 当てはめに要る最小の点数。これを下回る線は形を決める根拠が足りないので近似しない
    private static let minimumPoints = 12
    /// 外れ値を軽くする繰り返しの回数。実測ではこの回数で重みが落ち着く
    private static let reweightRounds = 8
    /// 外れ値とみなす距離の下限（体の大きさに対する割合）。測定の常のばらつきまで外れ値にしないための床
    private static let outlierFloor = 0.012
    /// 外れ値とみなす距離（残差の中央値に対する倍率）。中央値のこの倍を超えた点から重みを落とす
    private static let outlierScale = 1.5
    /// 曲線を折れ線で描くための標本数。測定点より密にして、拡大しても角が見えないようにする
    private static let sampleCount = 240
    /// 当てはめた曲線が測定点から離れてよい上限（その軌跡自体の大きさに対する割合）。
    /// 測定がその軌跡の形に対して粗いと 6 個の制御点では形を追えず、線が別の形になる。
    /// 実測では壊れた区間が 38%・43% で、残る 92 区間はすべて 21% 以下だった
    private static let representationLimit = 0.25

    let start: Double
    let end: Double
    private let controls: [CGPoint]
    /// 正規化座標は縦横で尺度が違うので、当てはめの間だけ x に掛けて画素の比で測る
    private let aspect: Double
    /// 時刻順に並べた曲線上の点。再生位置に関わらず固定で、通過済みの線が再生のたびに変形しないようにする
    private let samples: [TrailPoint]

    /// - points: 1 本の線の測定点（時刻順・欠測や飛びで切れていないこと）
    /// - aspect: 表示される映像の縦横比（幅 ÷ 高さ）
    /// - bodyScale: 体の大きさ（外れ値の判定の尺度）
    init?(points: [TrailPoint], aspect: Double, bodyScale: Double) {
        guard aspect.isFinite, aspect > 0, bodyScale.isFinite, bodyScale > 0,
              Self.isContinuous(points), let first = points.first, let last = points.last else { return nil }
        // NOTE: ここから下は self のプロパティを読まない（初期化の途中で self を閉じ込めるとコンパイルが通らない）
        let (from, span) = (first.time, last.time - first.time)
        let positions = points.map { CGPoint(x: $0.point.x * aspect, y: $0.point.y) }
        let rows = points.map { Self.basis(($0.time - from) / span) }
        guard let fitted = Self.controlPoints(positions: positions, rows: rows, bodyScale: bodyScale),
              Self.represents(positions, rows: rows, controls: fitted) else { return nil }

        start = from
        end = last.time
        self.aspect = aspect
        controls = fitted
        samples = (0...Self.sampleCount).map { i in
            let u = Double(i) / Double(Self.sampleCount)
            return TrailPoint(time: from + u * span,
                              point: Self.place(Self.evaluate(Self.basis(u), controls: fitted), aspect: aspect))
        }
    }

    /// 曲線上のその時刻の位置（区間の外なら nil）
    func point(at time: Double) -> CGPoint? {
        guard time.isFinite, start...end ~= time else { return nil }
        return Self.place(Self.evaluate(Self.basis((time - start) / (end - start)), controls: controls), aspect: aspect)
    }

    /// 再生位置までに通った分の点列。先端はその時刻ちょうどの点なので、丸と線がずれない
    func points(until time: Double) -> [TrailPoint] {
        guard time.isFinite, time >= start else { return [] }
        var result = Array(samples.prefix { $0.time <= time })
        if time < end, result.last?.time != time, let tip = point(at: time) {
            result.append(TrailPoint(time: time, point: tip))
        }
        return result
    }

    /// 部位・欠測で分かれた線・スイング区間の組。番号は保存せず描画の照合だけに使う。
    struct Key: Hashable {
        let part: BodyPart
        let stroke: Int
        let section: Int
    }

    /// トップ・インパクトで分け、境界以降の最初の点を共有して継ぎ目をつなぐ。
    static func sections(of stroke: [TrailPoint], phases: PhaseSet) -> [(index: Int, points: [TrailPoint])] {
        var remaining = stroke
        var result: [(index: Int, points: [TrailPoint])] = []
        for (index, boundary) in [phases.top, phases.impact].enumerated() {
            let before = Array(remaining.prefix { $0.time < boundary })
            if !before.isEmpty {
                let points = before + remaining.dropFirst(before.count).prefix(1)
                if points.count >= 2 { result.append((index, points)) }
            }
            remaining = Array(remaining.dropFirst(before.count))
        }
        if remaining.count >= 2 { result.append((2, remaining)) }
        return result
    }

    /// 全部位について、各連続線の 3 区間を別々に近似する。
    /// 近似できない区間（点が足りない・計算できない・測定点を代表できない）は組に入らず、描画側は通常の曲線に戻る
    static func prepare(trails: JointTrails, phases: PhaseSet, aspect: Double) -> [Key: TrailFit] {
        guard aspect.isFinite, aspect > 0, let bodyScale = bodyScale(of: trails, aspect: aspect) else { return [:] }
        var result: [Key: TrailFit] = [:]
        for part in BodyPart.allCases {
            for (index, stroke) in trails.strokes(of: part, in: phases.address...phases.finish).enumerated() {
                for section in sections(of: stroke, phases: phases) {
                    result[Key(part: part, stroke: index, section: section.index)] = TrailFit(
                        points: section.points, aspect: aspect, bodyScale: bodyScale)
                }
            }
        }
        return result
    }

    // MARK: - 中身

    /// 当てはめた曲線が測定点の代わりになっているか。測定がその軌跡の形に対して粗いと、
    /// 6 個の制御点では形を追いきれず、輪が潰れて別の形の線になる。そのときは近似をあきらめて通常の描画に戻す
    /// （実測は docs/research/260915_0527-body-trail-fitting.md §4）
    private static func represents(_ positions: [CGPoint], rows: [[Double]], controls: [CGPoint]) -> Bool {
        let box = positions.reduce(CGRect(origin: positions[0], size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        let extent = hypot(box.width, box.height)
        guard extent > 0 else { return false }   // 1 点に潰れた線。近似しても見た目は変わらない
        let residuals = rows.indices
            .map { Double(evaluate(rows[$0], controls: controls).distance(to: positions[$0])) }
            .sorted()
        // 端の数点だけの外れは丸めたいので最大ではなく 95 パーセンタイルで見る
        return residuals[Int(Double(residuals.count - 1) * 0.95)] <= Double(extent) * representationLimit
    }

    /// 当てはめに使った縦横比を外して、正規化座標へ戻す
    private static func place(_ fitted: CGPoint, aspect: Double) -> CGPoint {
        CGPoint(x: fitted.x / aspect, y: fitted.y)
    }

    /// 1 本の線として当てはめてよい点列か（時刻順で、欠測も飛びも無く、値が有限で、点数が足りている）
    private static func isContinuous(_ points: [TrailPoint]) -> Bool {
        guard points.count >= minimumPoints,
              points.allSatisfy({ $0.time.isFinite && $0.point.x.isFinite && $0.point.y.isFinite }) else { return false }
        return points.indices.dropFirst().allSatisfy { JointTrails.connects(points, at: $0) }
    }

    /// 肩の中点と股関節の中点の距離（の中央値）。外れ値の判定に使う体の大きさで、
    /// 検出で使う `PoseTrack.torsoHeight`（首〜腰）とは別物（軌跡には首も腰も入っていない）。
    /// 胴体が 1 コマも見えなければ nil（近似の当否を判断できないので通常の描画に戻す）
    private static func bodyScale(of trails: JointTrails, aspect: Double) -> Double? {
        trails.samples.compactMap { sample -> Double? in
            guard let ls = sample.leftShoulder, let rs = sample.rightShoulder,
                  let lh = sample.leftHip, let rh = sample.rightHip else { return nil }
            let dx = Double(ls.x + rs.x - lh.x - rh.x) * aspect / 2
            let dy = Double(ls.y + rs.y - lh.y - rh.y) / 2
            let length = hypot(dx, dy)
            return length.isFinite && length > 0 ? length : nil
        }.median
    }

    /// 6 個の制御点。両端は測定点の端に固定し（トップで次の線につながる）、内側の 4 個を最小二乗で解く。
    /// 単発の誤検出に引かれないよう、残差の大きい点を軽くしながら `reweightRounds` 回解き直す
    private static func controlPoints(positions: [CGPoint], rows: [[Double]], bodyScale: Double) -> [CGPoint]? {
        let ends = [positions[0], positions[positions.count - 1]]
        var weights = [Double](repeating: 1, count: positions.count)
        var controls: [CGPoint] = []
        for _ in 0..<reweightRounds {
            guard let inside = solve(normalEquations(positions: positions, rows: rows, ends: ends, weights: weights)) else {
                return nil
            }
            controls = [ends[0]] + inside + [ends[1]]
            let residuals = rows.indices.map { Double(evaluate(rows[$0], controls: controls).distance(to: positions[$0])) }
            let limit = max(bodyScale * outlierFloor, median(of: residuals) * outlierScale)
            weights = residuals.map { min(1, limit / max($0, 1e-12)) }
        }
        return controls.allSatisfy { $0.x.isFinite && $0.y.isFinite } ? controls : nil
    }

    /// 内側の制御点 4 個についての正規方程式（4 行 × 「係数 4 ＋ x と y の右辺」）。
    /// x と y は同じ左辺を共有するので、右辺だけ 2 列持って一度に解く
    private static func normalEquations(positions: [CGPoint], rows: [[Double]],
                                        ends: [CGPoint], weights: [Double]) -> [[Double]] {
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 4)
        for i in rows.indices {
            let row = rows[i]
            // 両端は固定なので、その寄与を測定点から引いた残りを内側の 4 個で当てはめる
            let target = CGPoint(x: positions[i].x - row[0] * ends[0].x - row[5] * ends[1].x,
                                 y: positions[i].y - row[0] * ends[0].y - row[5] * ends[1].y)
            for j in 0..<4 {
                let w = weights[i] * row[j + 1]
                for k in 0..<4 { matrix[j][k] += w * row[k + 1] }
                matrix[j][4] += w * target.x
                matrix[j][5] += w * target.y
            }
        }
        return matrix
    }

    /// 残差の中央値（偶数個なら中央 2 つの平均）。
    /// NOTE: 検出で使う `Collection.median` は中央の上側を返す。ここは点が 1 つ増減しただけで
    ///       外れ値のしきい値が飛ばないように平均を取る
    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// 位置 u（0〜1）での 6 個の基底の値（3 次 B スプライン。両端は 4 重節点なので端点を通る）
    private static func basis(_ u: Double) -> [Double] {
        if u >= 1 { return [0, 0, 0, 0, 0, 1] }
        let knots = [0.0, 0, 0, 0, 1.0 / 3, 2.0 / 3, 1, 1, 1, 1]
        var row = (0..<9).map { u >= knots[$0] && u < knots[$0 + 1] ? 1.0 : 0.0 }
        for degree in 1...3 {
            var next = [Double](repeating: 0, count: row.count - 1)
            for j in next.indices {
                let left = knots[j + degree] - knots[j]
                let right = knots[j + degree + 1] - knots[j + 1]
                if left > 0 { next[j] += (u - knots[j]) / left * row[j] }
                if right > 0 { next[j] += (knots[j + degree + 1] - u) / right * row[j + 1] }
            }
            row = next
        }
        return row
    }

    private static func evaluate(_ row: [Double], controls: [CGPoint]) -> CGPoint {
        zip(row, controls).reduce(.zero) { CGPoint(x: $0.x + $1.0 * $1.1.x, y: $0.y + $1.0 * $1.1.y) }
    }

    /// 4 元連立方程式を部分ピボットで解く。解けない（点が退化している）ときは nil を返し、描画側は通常の曲線に戻る
    private static func solve(_ input: [[Double]]) -> [CGPoint]? {
        var a = input
        let threshold = max((0..<4).map { abs(a[$0][$0]) }.max() ?? 0, 1) * 1e-10
        for col in 0..<4 {
            guard let pivot = (col..<4).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > threshold else { return nil }
            a.swapAt(col, pivot)
            let divisor = a[col][col]
            for j in col..<6 { a[col][j] /= divisor }
            for row in 0..<4 where row != col {
                let multiplier = a[row][col]
                for j in col..<6 { a[row][j] -= multiplier * a[col][j] }
            }
        }
        return a.map { CGPoint(x: $0[4], y: $0[5]) }
    }
}
