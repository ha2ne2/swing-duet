import Foundation
import Testing
@testable import SwingDuet

/// ジョグホイールの回転を目盛りに数え、回し続けた周回でギア（1 目盛りのコマ数）を上げる `JogRotation` を固定する（1 目盛り 12°）
struct JogRotationTests {

    /// 帯の上の指。角度（度）と時刻を進めながら `rotation` に渡す
    private struct Finger {
        var rotation = JogRotation(degreesPerDetent: 12)
        var angle = 0.0
        var time = Date(timeIntervalSinceReferenceDate: 0)

        /// 指を置く（最初の点）
        mutating func touch() -> Int {
            rotation.update(angle: angle * .pi / 180, at: time)
        }

        /// `degrees` ずつ `interval` 秒おきに `count` 回動かし、返った目盛りの数を並べる
        mutating func move(by degrees: Double, every interval: TimeInterval, count: Int) -> [Int] {
            (0..<count).map { _ in
                time += interval
                angle += degrees
                return rotation.update(angle: angle * .pi / 180, at: time)
            }
        }

        /// 1 周回す。親指の癖を真似て、伸ばす区間（90°）は 3 倍速く動かす。
        /// ちょうど 360° は浮動小数の丸めで境目に乗るので、実際の指と同じく少し余分（365°）に回す
        mutating func lap(clockwise: Bool = true) {
            let sign = clockwise ? 1.0 : -1.0
            _ = move(by: sign * 15, every: 1.0 / 60, count: 6)     // 速い区間：90° を 0.1 秒
            _ = move(by: sign * 5, every: 1.0 / 60, count: 55)     // 遅い区間：275° を 0.9 秒
        }

        mutating func wait(_ seconds: TimeInterval) {
            time += seconds
        }
    }

    @Test func firstTouchCountsNothing() {
        var finger = Finger(angle: 45)
        #expect(finger.touch() == 0)
        #expect(finger.rotation.totalDegrees == 0)
        #expect(finger.rotation.framesPerDetent == 1)
    }

    @Test func smallMovesAccumulateIntoDetentsAndKeepTheRemainder() {
        var finger = Finger()
        _ = finger.touch()
        #expect(finger.move(by: 5, every: 0.1, count: 6) == [0, 0, 1, 0, 1, 0])   // 5° ずつ 30° まで。12° と 24° で 1 目盛りずつ
        #expect(abs(finger.rotation.totalDegrees - 30) < 1e-9)
        #expect(finger.move(by: 6, every: 0.1, count: 1) == [1])   // 持ち越し 6° + 6° で 3 つ目
    }

    @Test func counterclockwiseIsNegative() {
        var finger = Finger(angle: 90)
        _ = finger.touch()
        #expect(finger.move(by: -30, every: 0.1, count: 1) == [-2])   // −2 目盛り、持ち越し −6°
        #expect(finger.move(by: -6, every: 0.1, count: 1) == [-1])
    }

    @Test func crossingTheSeamAtPlusMinusPiIsNotAFullTurn() {
        // atan2 は ±180° で飛ぶので、170° の次に −170° が来る（時計回りに 20° 進んだだけ）
        var rotation = JogRotation(degreesPerDetent: 12)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        _ = rotation.update(angle: 170 * .pi / 180, at: start)
        #expect(rotation.update(angle: -170 * .pi / 180, at: start + 0.1) == 1)
        #expect(abs(rotation.totalDegrees - 20) < 1e-9)
        _ = rotation.update(angle: -179 * .pi / 180, at: start + 0.2)
        #expect(rotation.update(angle: 175 * .pi / 180, at: start + 0.3) == 0)   // 反時計回りに 6° 戻った
        #expect(abs(rotation.totalDegrees - 5) < 1e-9)
    }

    @Test func oneBigMoveYieldsSeveralDetents() {
        var finger = Finger()
        _ = finger.touch()
        #expect(finger.move(by: 40, every: 0.1, count: 1) == [3])
    }

    @Test func gearDoublesEveryLapUpToFour() {
        var finger = Finger()
        _ = finger.touch()
        #expect(finger.rotation.framesPerDetent == 1)
        finger.lap()
        #expect(finger.rotation.framesPerDetent == 2)
        finger.lap()
        #expect(finger.rotation.framesPerDetent == 4)
        finger.lap()
        #expect(finger.rotation.framesPerDetent == 4)   // 上限
    }

    @Test func gearIsConstantWithinALapEvenIfTheThumbSpeedsUp() {
        var finger = Finger()
        _ = finger.touch()
        _ = finger.move(by: 15, every: 1.0 / 60, count: 6)    // 速い区間の途中でも
        #expect(finger.rotation.framesPerDetent == 1)
        _ = finger.move(by: 5, every: 1.0 / 60, count: 40)    // 遅い区間でも、1 周目は 1 コマ
        #expect(finger.rotation.framesPerDetent == 1)
    }

    @Test func reversingDropsBackToFirstGear() {
        var finger = Finger()
        _ = finger.touch()
        finger.lap()
        finger.lap()
        #expect(finger.rotation.framesPerDetent == 4)
        _ = finger.move(by: -5, every: 1.0 / 60, count: 1)    // 目盛りに満たない揺れでは戻らない
        #expect(finger.rotation.framesPerDetent == 4)
        _ = finger.move(by: -5, every: 1.0 / 60, count: 4)    // 逆向きに 1 目盛り越えたら（持ち越し分を含めて 25°）1 コマに戻る
        #expect(finger.rotation.framesPerDetent == 1)
        finger.lap(clockwise: false)                          // 逆向きに回し続ければまた上がる
        #expect(finger.rotation.framesPerDetent == 2)
    }

    @Test func pausingDropsBackToFirstGear() {
        var finger = Finger()
        _ = finger.touch()
        finger.lap()
        #expect(finger.rotation.framesPerDetent == 2)
        finger.wait(0.5)
        _ = finger.move(by: 5, every: 1.0 / 60, count: 1)
        #expect(finger.rotation.framesPerDetent == 1)
    }

    @Test func endResetsEverything() {
        var finger = Finger()
        _ = finger.touch()
        finger.lap()
        _ = finger.move(by: 11, every: 1.0 / 60, count: 1)
        finger.rotation.end()
        #expect(finger.rotation.totalDegrees == 0)
        #expect(finger.rotation.framesPerDetent == 1)
        finger.wait(1)
        #expect(finger.touch() == 0)                                 // 新しい接触の最初の点
        #expect(finger.move(by: 11, every: 0.1, count: 1) == [0])   // 持ち越しが消えているので 11° では届かない
    }
}
