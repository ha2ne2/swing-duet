import Testing
import Foundation
@testable import SwingDuet

/// 撮影の区切りファイル（`SegmentWriter.Segment`）の時刻の扱いを固定する。
/// ショットのインパクトがどのファイルに入るか（`contains`）と、セッション秒をファイルの秒に直す計算（`localRange`）を間違えると、
/// 打った球が黙って消えるか、保存したクリップのフェーズが別の場所を指す
struct SegmentWriterTests {

    private func segment(_ start: Double, _ end: Double) -> SegmentWriter.Segment {
        SegmentWriter.Segment(id: UUID(), url: URL(fileURLWithPath: "/tmp/x.mov"), start: start, end: end, droppedFrames: 0)
    }

    @Test func containsIncludesBothEnds() {
        let s = segment(10, 70)
        #expect(s.contains(10) && s.contains(70) && s.contains(40))
        #expect(!s.contains(9.99) && !s.contains(70.01))
    }

    @Test func localRangeIsMeasuredFromTheFirstFrameOfTheFile() {
        let range = segment(10, 70).localRange(of: 20...25)
        #expect(range == 10...15)
    }

    @Test func localRangeIsTrimmedToTheFile() {
        let s = segment(10, 70)
        #expect(s.localRange(of: 5...25) == 0...15)      // 頭が前のファイルに掛かる
        #expect(s.localRange(of: 60...90) == 50...60)    // 尻が次のファイルに掛かる
    }

    @Test func localRangeIsNilWhenNothingOverlaps() {
        let s = segment(10, 70)
        #expect(s.localRange(of: 80...90) == nil)
        #expect(s.localRange(of: 0...5) == nil)
        #expect(s.localRange(of: 70...80) == nil)   // 端で 1 コマも残らない
    }
}
