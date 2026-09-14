import SwiftUI

/// 再生位置までの軌跡を、動画と同じ変換で重ねる。線の太さは拡大率に依存しない。
/// 近似がある区間は区間全体に当てはめた曲線、無い区間は測定点の近くを通る B スプラインで結ぶ。
struct JointTrailOverlay: View {
    /// 軌跡の表示のオン・オフ（`UserDefaults` のキー。ステージ右上のボタンで切り替え、アプリ全体で 1 つ）
    static let isEnabledKey = "showJointTrails"
    /// 隠している部位の組（`TrailPartGroup.bit` の和。ステージ右上の「…」で切り替え、アプリ全体で 1 つ）
    static let hiddenPartsKey = "hiddenJointTrailParts"
    /// 近似のオン・オフ（ステージ右上の「…」で切り替え、アプリ全体で 1 つ）。
    /// NOTE: 手だけに掛けていた頃のキー名のまま。**変えると切っていた人の設定が既定（オン）へ戻る**ので据え置く
    static let smoothingKey = "smoothHandTrails"

    let trails: JointTrails
    /// 描く部位（ステージ右上の「…」で選んだもの）
    let parts: [BodyPart]
    /// 各部位のスイング区間の近似（`JointTrails.strokes` の並び順。空なら通常の曲線で描く）。
    /// NOTE: 作るのは重いので、毎コマ描き直されるこの View ではなく `VideoPaneView` が持つ
    let trailFits: [TrailFit.Key: TrailFit]
    let phases: PhaseSet
    /// いま映しているコマの時刻（その動画の秒）
    let now: Double
    /// 等倍・中央（resizeAspect）で表示したときの映像の位置（ペイン座標・pt）
    let videoRect: CGRect
    /// ペインの表示変換：ペイン中心を基準にした拡大率と、中心からのずれ（pt）
    let scale: Double
    let offset: CGSize

    private static let lineWidth: CGFloat = 3
    private static let dotRadius: CGFloat = 4
    /// 1 本の線に使う点の目安（末尾の 1 点だけ超えることがある）。240fps 原本のスイングは解析コマが 600 を超えることがあり、
    /// 全部を毎コマ描くと 2 つのペインで曲線が 1 万区間になる。この密度でも曲線は十分滑らかなので、多いときは等間隔に間引く
    private static let maxPoints = 80

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Vision の正規化座標（左下原点）→ 等倍で表示される映像の上の位置 → ペインの表示変換（中心を基準に拡大してからずらす）
            func place(_ p: CGPoint) -> CGPoint {
                let fitted = CGPoint(x: videoRect.minX + p.x * videoRect.width, y: videoRect.minY + (1 - p.y) * videoRect.height)
                return CGPoint(
                    x: center.x + (fitted.x - center.x) * scale + offset.width,
                    y: center.y + (fitted.y - center.y) * scale + offset.height)
            }
            // 軌跡はスイング区間だけを描くので、その外（同期しないときは共通タイムラインが区間の外まで伸びる）では
            // いまの位置も出さない。出すと線の無いところに丸だけが浮く
            let swing = phases.address...phases.finish
            for part in parts {
                let color = (before: part.color(afterTop: false), after: part.color(afterTop: true))
                let lines = lines(of: part, in: swing)
                let tip = swing.contains(now) ? Self.tip(of: lines, at: now) : nil
                for line in lines {
                    guard let path = Self.path(for: line, until: now, tip: tip, place: place) else { continue }
                    context.stroke(
                        path,
                        with: .color(line.afterTop ? color.after : color.before),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                }
                if let tip {
                    let dot = CGRect(origin: place(tip), size: .zero).insetBy(dx: -Self.dotRadius, dy: -Self.dotRadius)
                    context.fill(Path(ellipseIn: dot), with: .color(now < phases.top ? color.before : color.after))
                    context.stroke(Path(ellipseIn: dot), with: .color(.white.opacity(0.85)), lineWidth: 1)
                }
            }
        }
    }

    /// 1 本ぶんの線。近似がある区間はその曲線で、無ければ測定点から描く
    private typealias Line = (points: [TrailPoint], afterTop: Bool, fit: TrailFit?)

    /// 近似が 1 つも無い＝近似オフ（または作成中）。そのときは分割も丸の位置も含めて従来の描画に戻す
    private var isSmoothed: Bool { !trailFits.isEmpty }

    /// その部位に描く線の一覧。近似ありならトップとインパクトで 3 つ、無しならトップで 2 つに分ける
    private func lines(of part: BodyPart, in swing: ClosedRange<Double>) -> [Line] {
        var result: [Line] = []
        for (index, stroke) in trails.strokes(of: part, in: swing).enumerated() {
            if isSmoothed {
                result += TrailFit.sections(of: stroke, phases: phases).map {
                    ($0.points, $0.index > 0, trailFits[TrailFit.Key(part: part, stroke: index, section: $0.index)])
                }
            } else {
                result += Self.split(stroke, atTop: phases.top).map { ($0.points, $0.afterTop, nil) }
            }
        }
        return result
    }

    /// 丸と線の先の位置。近似がある区間はその曲線から、無ければ測定点の線の上から取る。
    /// 線と同じところから出さないと、近似した線から丸が浮く。
    /// その部位の線だけを見る（全部位から拾うと、腰の丸が手の曲線の上に乗る）
    private static func tip(of lines: [Line], at now: Double) -> CGPoint? {
        lines.lazy.compactMap { $0.fit?.point(at: now) }.first
            ?? JointTrails.position(on: lines.map(\.points), at: now)
    }

    /// 1 本の線の形。近似があればその曲線をそのまま結び、無ければ測定点を間引いて近くを通る曲線にする。
    /// 線にならない（点が 1 つ）ときは nil
    private static func path(for line: Line, until now: Double, tip: CGPoint?,
                             place: (CGPoint) -> CGPoint) -> Path? {
        if let fit = line.fit {
            let fitted = fit.points(until: now)
            guard fitted.count >= 2 else { return nil }
            // 近似は既に滑らかなので、間引きも曲線化も重ねて掛けない
            return Path { $0.addLines(fitted.map { place($0.point) }) }
        }
        let played = played(line.points, until: now, tip: tip)
        guard played.count >= 2 else { return nil }
        return curve(through: played.map { place($0.point) })
    }

    /// 線をトップで 2 つに分ける（トップより前・トップ以降）。継ぎ目が切れないように、前半はトップ以降の最初の点まで伸ばす
    static func split(_ stroke: [TrailPoint], atTop top: Double) -> [(points: [TrailPoint], afterTop: Bool)] {
        let before = Array(stroke.prefix { $0.time < top })
        let after = Array(stroke.drop { $0.time < top })
        var parts: [(points: [TrailPoint], afterTop: Bool)] = []
        if !before.isEmpty { parts.append((before + after.prefix(1), false)) }
        if !after.isEmpty { parts.append((after, true)) }
        return parts.filter { $0.points.count >= 2 }
    }

    /// 線のうち再生位置までに通った分（間引き済み）。
    /// 間引きは線の全体に対して行う（再生位置までに掛けると、進むたびに採る点が入れ替わって線が揺れる）。
    /// 間引きで消えた分があるときは、いまの位置（`tip`）を足して線の先を再生位置に合わせる。
    /// 点が 1 つしか無ければ空を返す（線が引けないので、丸だけが浮くのを避ける）
    static func played(_ points: [TrailPoint], until now: Double, tip: CGPoint?) -> [TrailPoint] {
        let shown = thinned(points)
        var played = Array(shown.prefix { $0.time <= now })   // 点は時刻順
        if !played.isEmpty, played.count < shown.count, let tip {
            played.append(TrailPoint(time: now, point: tip))
        }
        return played.count >= 2 ? played : []
    }

    /// 点が多すぎる線を等間隔に間引く（最後の点は必ず残す）
    static func thinned(_ points: [TrailPoint]) -> [TrailPoint] {
        guard points.count > maxPoints else { return points }
        let step = Int((Double(points.count) / Double(maxPoints)).rounded(.up))
        var result = points.enumerated().filter { $0.offset % step == 0 }.map(\.element)
        if let last = points.last, result.last?.time != last.time { result.append(last) }
        return result
    }

    /// 点の近くを通る滑らかな曲線（一様 3 次 B スプラインを 3 次ベジェに直したもの）。2 点なら直線。
    ///
    /// NOTE: 点を必ず通る曲線（Catmull–Rom）だと、姿勢推定のブレがそのまま角として出る。曲線が測定点を通ることを
    ///       強いられるので仕組み上避けられない。スイングは連続した運動なので、点は通らず近くを通す方が形に忠実で、
    ///       線の曲がりの揺れは半分になる（実測は docs/research/260914_0311-joint-trail-smoothing.md §7）。
    ///       端の制御点を 2 つずつ重ねて、線の始まりと先だけは点にちょうど届かせる（先は再生位置に合わせるため）
    static func curve(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: last) }
            return path
        }
        let control = [first, first] + points + [last, last]
        for i in 0..<(control.count - 3) {
            let (b, c, d) = (control[i + 1], control[i + 2], control[i + 3])
            path.addCurve(
                to: CGPoint(x: (b.x + 4 * c.x + d.x) / 6, y: (b.y + 4 * c.y + d.y) / 6),
                control1: CGPoint(x: (2 * b.x + c.x) / 3, y: (2 * b.y + c.y) / 3),
                control2: CGPoint(x: (b.x + 2 * c.x) / 3, y: (b.y + 2 * c.y) / 3))
        }
        return path
    }
}
