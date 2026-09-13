import SwiftUI

/// 渡された部位の軌跡を動画に重ねて描く（どれを渡すかはステージ右上の「…」で決まる）。
/// 再生位置までに**通ったところだけ**を描き、いまの位置に丸を打つ（まだ通っていない先を薄く出すと、
/// 何本もの線が重なって形が読めなくなる）。
/// 色は部位ごとに色相を変え、トップより前は淡く、トップ以降は同じ色相の濃い色にする（`BodyPart.color`）。
/// 点は通らず、近くを通る曲線（B スプライン）でつなぐ。スイングは連続した運動なので、測定点を必ず通す必要はない。
/// 座標は正規化座標のまま持ち、描くときにペインの表示変換を掛ける（拡大しても線の太さは変わらない）
struct JointTrailOverlay: View {
    /// 軌跡の表示のオン・オフ（`UserDefaults` のキー。ステージ右上のボタンで切り替え、アプリ全体で 1 つ）
    static let isEnabledKey = "showJointTrails"
    /// 隠している部位の組（`TrailPartGroup.bit` の和。ステージ右上の「…」で切り替え、アプリ全体で 1 つ）
    static let hiddenPartsKey = "hiddenJointTrailParts"

    let trails: JointTrails
    /// 描く部位（ステージ右上の「…」で選んだもの）
    let parts: [BodyPart]
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
                let current = swing.contains(now) ? trails.point(of: part, at: now) : nil   // 線の先と丸に使う
                for stroke in trails.strokes(of: part, in: swing) {
                    for (points, afterTop) in Self.split(stroke, atTop: phases.top) {
                        // 間引きは線の全体に対して行う（再生位置までに掛けると、進むたびに採る点が入れ替わって線が揺れる）
                        let shown = Self.thinned(points)
                        var played = shown.filter { $0.time <= now }
                        // 間引きで消えた分は、いまの点を足して線の先を現在位置に合わせる
                        if !played.isEmpty, played.count < shown.count, let current {
                            played.append(TrailPoint(time: now, point: current))
                        }
                        guard played.count >= 2 else { continue }
                        context.stroke(
                            Self.curve(through: played.map { place($0.point) }),
                            with: .color(afterTop ? color.after : color.before),
                            style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                    }
                }
                if let current {
                    let dot = CGRect(origin: place(current), size: .zero).insetBy(dx: -Self.dotRadius, dy: -Self.dotRadius)
                    context.fill(Path(ellipseIn: dot), with: .color(now < phases.top ? color.before : color.after))
                    context.stroke(Path(ellipseIn: dot), with: .color(.white.opacity(0.85)), lineWidth: 1)
                }
            }
        }
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
            let (a, b, c, d) = (control[i], control[i + 1], control[i + 2], control[i + 3])
            path.addCurve(
                to: CGPoint(x: (b.x + 4 * c.x + d.x) / 6, y: (b.y + 4 * c.y + d.y) / 6),
                control1: CGPoint(x: (2 * b.x + c.x) / 3, y: (2 * b.y + c.y) / 3),
                control2: CGPoint(x: (b.x + 2 * c.x) / 3, y: (b.y + 2 * c.y) / 3))
        }
        return path
    }
}
