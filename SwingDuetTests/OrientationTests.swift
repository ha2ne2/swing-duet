import Testing
import CoreGraphics
import ImageIO
@testable import SwingDuet

/// 動画の回転行列 → Vision に渡す向きの写像を固定する。撮影のライブ追跡と、保存した動画の後解析が同じ写像を使う。
/// 2026-09-13 に `CGAffineTransform(rotationAngle:)` で作った縦撮りの行列（cos(π/2) が 6e-17）が `.up` と読まれ、人物を横倒しのまま追跡した
struct OrientationTests {

    /// カメラアプリやファイルの厳密な行列
    @Test func exactMatricesMapToTheirOrientation() {
        #expect(PoseTracker.orientation(from: .identity) == .up)
        #expect(PoseTracker.orientation(from: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)) == .right)
        #expect(PoseTracker.orientation(from: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)) == .left)
        #expect(PoseTracker.orientation(from: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)) == .down)
    }

    /// 三角関数で作った行列（成分が厳密な 0 / ±1 にならない）も同じ向きになる
    @Test func inexactRotationMatricesMapToTheSameOrientation() {
        #expect(PoseTracker.orientation(from: CGAffineTransform(rotationAngle: .pi / 2)) == .right)
        #expect(PoseTracker.orientation(from: CGAffineTransform(rotationAngle: -.pi / 2)) == .left)
        #expect(PoseTracker.orientation(from: CGAffineTransform(rotationAngle: .pi)) == .down)
        #expect(PoseTracker.orientation(from: CGAffineTransform(rotationAngle: 3 * .pi / 2)) == .left)
    }

    /// 撮影で使う回転行列は 90° 単位で厳密な整数。縦撮り（90°）の向きは `.right`、横撮りは `.up`、逆さは `.down`
    @Test func captureRotationIsExactAndConsistentWithTheOrientation() {
        let portrait = CGAffineTransform.rotation(degrees: 90)
        #expect(portrait == CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))
        #expect(PoseTracker.orientation(from: portrait) == .right)
        #expect(PoseTracker.orientation(from: .rotation(degrees: 0)) == .up)
        #expect(PoseTracker.orientation(from: .rotation(degrees: 180)) == .down)
        #expect(PoseTracker.orientation(from: .rotation(degrees: 270)) == .left)
        #expect(PoseTracker.orientation(from: .rotation(degrees: -90)) == .left)
        #expect(CGAffineTransform.rotation(degrees: 360) == .identity)
    }

    /// 表示される向きでの縦横比。90° 回す向きでは縦横が入れ替わる
    /// （胴体が縦向きかの判定に使う。取り違えると縦撮りの後方視点で前傾したゴルファーを弾いてしまう）
    @Test func shownAspectSwapsWidthAndHeightForQuarterTurns() {
        #expect(PoseTracker.shownAspect(width: 1920, height: 1080, orientation: .up) == 1920.0 / 1080)
        #expect(PoseTracker.shownAspect(width: 1920, height: 1080, orientation: .down) == 1920.0 / 1080)
        #expect(PoseTracker.shownAspect(width: 1920, height: 1080, orientation: .right) == 1080.0 / 1920)
        #expect(PoseTracker.shownAspect(width: 1920, height: 1080, orientation: .left) == 1080.0 / 1920)
        #expect(PoseTracker.shownAspect(width: 0, height: 0, orientation: .up) == 1)
    }
}
