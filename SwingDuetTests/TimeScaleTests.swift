import Testing
import Foundation
@testable import SwingDuet

/// 時間軸と幅の対応（シークバー・フェーズ調整・プレビューが共通で使う）を固定する
struct TimeScaleTests {

    private let scale = TimeScale(duration: 4, width: 200)

    @Test func timeMapsToXAndBack() {
        #expect(scale.x(of: 1) == 50)
        #expect(scale.time(atX: 50) == 1)
        #expect(scale.time(movedBy: 50) == 1)   // 移動量は差なので符号だけ意味がある
        #expect(scale.time(movedBy: -50) == -1)
    }

    @Test func theEndsAreClampedExceptWhenAsked() {
        #expect(scale.x(of: -1) == 0)
        #expect(scale.x(of: 99) == 200)
        #expect(scale.time(atX: -20) == 0)
        #expect(scale.time(atX: 400) == 4)
        #expect(scale.time(atX: -20, clamping: false) == -0.4)   // シークバーは端の外も渡す（受け手が収める）
    }

    @Test func zeroSizedScalesDoNotDivideByZero() {
        #expect(TimeScale(duration: 0, width: 200).x(of: 1) == 0)
        #expect(TimeScale(duration: 4, width: 0).time(atX: 10) == 4)   // 幅 0 では右端に振り切る（0 除算しない）
    }
}
