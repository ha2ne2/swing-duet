import Foundation
import AVFoundation

/// 撮影のフレームを HEVC の区切りファイルに書く（`AVAssetWriter`）。すべて撮影のキュー（`CaptureSession.queue`）で呼ぶ。
///
/// 区切りは `rotate` で切り替える（次のフレームから新しいファイルに書くだけで、フレームは落とさない）。ファイルの時刻はそのファイルの
/// 最初のフレームが 0 で、セッション秒との差は `Segment.start`。ショットの範囲（セッション秒）をファイルの秒に直すのに使う。
/// 設計は docs/design/260912_1951-in-app-slowmo-capture-and-shot-split.md §4.2
final class SegmentWriter {
    /// 閉じた区切りファイル
    struct Segment: Identifiable, Equatable {
        let id: UUID
        let url: URL
        /// 最初のフレームの時刻（セッション秒）
        let start: Double
        /// 最後のフレームの時刻（セッション秒）
        let end: Double
        /// この区切りまでにエンコーダが追い付かず書けなかったフレームの累計（実機で確かめる指標）
        let droppedFrames: Int

        /// セッション秒の時刻がこのファイルの中か
        func contains(_ time: Double) -> Bool {
            start <= time && time <= end
        }

        /// セッション秒の範囲をこのファイルの秒に直す（ファイルの外は切り詰める）
        func localRange(of range: ClosedRange<Double>) -> ClosedRange<Double>? {
            let lower = max(range.lowerBound, start) - start
            let upper = min(range.upperBound, end) - start
            return upper > lower ? lower...upper : nil
        }
    }

    enum Error: Swift.Error {
        case cannotStart(String)
    }

    private let directory: URL
    private let settings: [String: Any]
    private let transform: CGAffineTransform

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var current: (id: UUID, url: URL, start: Double, last: Double)?
    /// エンコーダが追い付かず書けなかったフレームの数（閉じた `Segment` に写して実機で確かめる）
    private var droppedFrames = 0

    /// 調査用のログ（`Documents/CaptureLogs`）。実機では print が読めないので、失敗はここに残す
    private let log: CaptureLog?

    /// - settings: `AVAssetWriterInput` の映像の設定（`CaptureSession.recommendedVideoSettings`）
    /// - transform: 動画の向き（開始時の端末の向き。`preferredTransform` になる）
    init(directory: URL, settings: [String: Any], transform: CGAffineTransform, log: CaptureLog?) {
        self.directory = directory
        self.settings = settings
        self.transform = transform
        self.log = log
    }

    /// フレームを書く。区切りの最初のフレームなら新しいファイルを始める
    func append(_ sample: CMSampleBuffer, at time: Double) throws {
        if writer == nil {
            try start(at: CMSampleBufferGetPresentationTimeStamp(sample), time: time)
        }
        guard let input, let writer else { return }
        guard writer.status == .writing else {
            throw Error.cannotStart(writer.error?.localizedDescription ?? "書き込みが中断されました")
        }
        if input.isReadyForMoreMediaData, input.append(sample) {
            current?.last = time
        } else {
            guard writer.status == .writing else {
                throw Error.cannotStart(writer.error?.localizedDescription ?? "フレームを書き込めません")
            }
            droppedFrames += 1
        }
    }

    /// いまの区切りを閉じる（次のフレームから新しいファイルに書く）。閉じ終わったら `completion`（任意のスレッド）
    func rotate(completion: @escaping (Segment?) -> Void) {
        guard let writer, let input, let current else {
            completion(nil)
            return
        }
        self.writer = nil
        self.input = nil
        self.current = nil
        input.markAsFinished()
        let segment = Segment(id: current.id, url: current.url, start: current.start, end: current.last, droppedFrames: droppedFrames)
        writer.finishWriting {
            if writer.status == .completed {
                completion(segment)
            } else {
                self.log?.line("segment close failed: \(writer.error?.localizedDescription ?? "")")
                try? FileManager.default.removeItem(at: segment.url)
                completion(nil)
            }
        }
    }

    private func start(at sourceTime: CMTime, time: Double) throws {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.transform = transform
        guard writer.canAdd(input) else { throw Error.cannotStart("入力を追加できません") }
        writer.add(input)
        guard writer.startWriting() else { throw Error.cannotStart(writer.error?.localizedDescription ?? "開始できません") }
        writer.startSession(atSourceTime: sourceTime)
        self.writer = writer
        self.input = input
        current = (UUID(), url, time, time)
    }
}
