import AVFoundation

/// 撮影のキュー（`CaptureSession.queue`）だけが触る状態：区切りファイルへの書き込みと、追跡へ渡すフレームの間引き
final class CaptureFrameWriter {
    private var writer: SegmentWriter?
    private var startPTS: Double?
    private var nextVisionAt = 0.0
    private var visionBusy = false
    private var closeRequested = false
    /// 追跡に渡す間隔（秒）。熱で下げる
    var visionInterval = 1 / LiveDetector.sampleRate
    /// 調査用のログ（撮影のキューから書く）
    var log: CaptureLog?
    /// 区切りファイルを始められなかった（任意のスレッド。呼び手が止める）
    var onWriteFailed: (() -> Void)?
    /// 追跡へ渡す（受け手は自分のキューで処理し、終わったら `visionFinished` を撮影のキューで呼ぶ）
    var onVision: ((CVPixelBuffer, Double) -> Void)?
    /// 区切りファイルが閉じた（メインアクターへ順に通知する）
    var onSegmentClosed: (@MainActor (SegmentWriter.Segment) -> Void)?
    /// 閉じている最中の全区切り。最後の区切りだけ待つと、それより前の完了通知が停止後に届いてしまう
    private let closing = DispatchGroup()

    func begin(with writer: SegmentWriter) {
        self.writer = writer
        startPTS = nil
        nextVisionAt = 0
        visionBusy = false
        closeRequested = false
    }

    func handle(_ sample: CMSampleBuffer) {
        guard let writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let start = startPTS ?? pts
        startPTS = start
        let time = pts - start
        if closeRequested {
            closeRequested = false
            close(writer)
        }
        do {
            try writer.append(sample, at: time)
        } catch {
            // NOTE: 1 度失敗したら諦める（容量不足だと 240fps で毎フレーム作り直しに行くことになる）。
            //       閉じたファイルまでは残るので、止めれば保存できる
            log?.line("segment start failed: \(error.localizedDescription)")
            self.writer = nil
            onWriteFailed?()
        }
        if time >= nextVisionAt, !visionBusy, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
            nextVisionAt = time + visionInterval
            visionBusy = true
            onVision?(pixelBuffer, time)
        }
    }

    func visionFinished() {
        visionBusy = false
    }

    func requestClose() {
        closeRequested = true
    }

    private func close(_ writer: SegmentWriter) {
        let closed = onSegmentClosed
        let closing = closing
        closing.enter()
        writer.rotate { segment in
            Task { @MainActor in
                if let segment { closed?(segment) }
                closing.leave()
            }
        }
    }

    /// 全区切りの書き込みと main への受け渡しを待ち切ってから終える
    func finish(completion: @escaping () -> Void) {
        if let writer {
            self.writer = nil
            close(writer)
        }
        closing.notify(queue: .main, execute: completion)
    }

}
