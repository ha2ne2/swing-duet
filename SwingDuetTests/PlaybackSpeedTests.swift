import Testing
@testable import SwingDuet

/// 再生速度ボタンの巡回（x1 → x1/2 → x1/4 → x1/8 → x1）と、プリセット外の値の寄せ方を固定する
@MainActor
struct PlaybackSpeedTests {

    @Test func cycleHalvesTheSpeedAndWrapsBackToOne() {
        #expect(PlaybackController.nextSpeed(after: 1.0) == 0.5)
        #expect(PlaybackController.nextSpeed(after: 0.5) == 0.25)
        #expect(PlaybackController.nextSpeed(after: 0.25) == 0.125)
        #expect(PlaybackController.nextSpeed(after: 0.125) == 1.0)
    }

    /// プリセットに無い値（前のプリセットで保存された設定）からは先頭の x1 へ
    @Test func cycleFromAnUnknownSpeedStartsOver() {
        #expect(PlaybackController.nextSpeed(after: 0.3) == 1.0)
    }

    /// 既定値もプリセットのどれか（PlaybackSettings のコメントの前提）
    @Test func defaultSpeedIsAPreset() {
        #expect(PlaybackController.speedPresets.contains(PlaybackSettings().speed))
    }

    @Test func nearestPresetSnapsSavedSpeeds() {
        #expect(PlaybackController.nearestPreset(to: 0.3) == 0.25)
        #expect(PlaybackController.nearestPreset(to: 0.1) == 0.125)
        #expect(PlaybackController.nearestPreset(to: 0.5) == 0.5)
        #expect(PlaybackController.nearestPreset(to: 4) == 1.0)
        #expect(PlaybackController.nearestPreset(to: 0) == 0.125)   // 壊れた値でも 0 は返さない（表記が 1 / speed のため）
    }
}
