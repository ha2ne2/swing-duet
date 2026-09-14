import AVFoundation
import ImageIO

/// 追跡のキューだけが触る状態：Vision の追跡（`FrameTracker`）、ライブ検出（`LiveDetector`）、区切りの計画（`SegmentPlanner`）
final class CapturePoseProcessor {
    struct Result {
        var stance: LiveDetector.StanceEvent? = nil
        /// 新しく見つかった候補（切り出して仮に保存する）
        var registered: [LiveShot] = []
        /// 本番か素振りかの判定
        var verdicts: [LiveShotJudge.Verdict] = []
        var closeSegment = false
        var personVisible = false
    }

    private var tracker = PoseTracker.FrameTracker()
    private var detector = LiveDetector()
    private var planner = SegmentPlanner()
    private let orientation: CGImagePropertyOrientation
    /// 撮影のフレームレート（仮の解析のクリップに書く。熱で変わる）
    var frameRate: Double
    private let videoAspect: Double
    private let log: CaptureLog?
    private var nextLogAt = 0.0

    init(orientation: CGImagePropertyOrientation, frameRate: Double, videoAspect: Double, log: CaptureLog?) {
        self.orientation = orientation
        self.frameRate = frameRate
        self.videoAspect = videoAspect
        self.log = log
    }

    func process(_ pixelBuffer: CVPixelBuffer, at time: Double) -> Result {
        let person = tracker.person(in: pixelBuffer, orientation: orientation)
        let frame = tracker.frame(at: time, person: person)
        let update = detector.add(frame)
        let quiet = detector.isQuiet(at: time)
        var close = false
        if planner.shouldClose(at: time, lastFinish: detector.lastFinish, quiet: quiet) {
            planner.didClose(at: time)
            close = true
            log?.line(String(format: "close segment t=%.2f lastFinish=%@ quiet=%d", time, detector.lastFinish.map { String(format: "%.2f", $0) } ?? "-", quiet ? 1 : 0))
        }
        for candidate in update.observed {
            let p = candidate.phases
            log?.line(String(format: "candidate A=%.2f T=%.2f I=%.2f F=%.2f rise=%.2f peak=%.2f estimated=%d pending=%d",
                             p.address, p.top, p.impact, p.finish, candidate.rise, candidate.peakSpeed, candidate.estimated.count, detector.judge.pending.count))
        }
        if time >= nextLogAt {
            nextLogAt = time + 1
            let hand = detector.currentHandHeight().map { String(format: "%.2f", $0) } ?? "-"
            let bounds = frame.bodyBounds.map { String(format: "[%.2f %.2f %.2f %.2f]", $0.minX, $0.minY, $0.maxX, $0.maxY) } ?? "-"
            log?.line(String(format: "t=%.2f person=%d wrist=%.0f%% hand=%@ bounds=%@ quiet=%d motion=%d pending=%d",
                             time, frame.bodyBounds == nil ? 0 : 1, detector.recentWristCoverage(at: time) * 100, hand, bounds,
                             quiet ? 1 : 0, detector.inMotion(at: time) ? 1 : 0, detector.judge.pending.count))
        }
        return Result(stance: update.stance, registered: update.registered.compactMap(liveShot), verdicts: update.verdicts,
                      closeSegment: close, personVisible: detector.isPersonVisible(at: time))
    }

    /// 止めるとき：待たずに全部決める
    func flush(at time: Double) -> Result {
        let flushed = detector.flush(at: time)
        log?.line(String(format: "flush t=%.2f registered=%d verdicts=%d frames=%d", time, flushed.registered.count, flushed.verdicts.count, detector.frames.count))
        return Result(registered: flushed.registered.compactMap(liveShot), verdicts: flushed.verdicts)
    }

    /// 候補に、切り出す範囲と、その範囲のライブ追跡を 1 本の動画として見た仮の解析（切り出したクリップにすぐ付けるフェーズ）を添える。
    /// 範囲が取れない候補（アドレスとフィニッシュが余白の分より近い）は切り出さない
    private func liveShot(_ candidate: SwingCandidate) -> LiveShot? {
        guard let range = ShotSplitter.range(of: candidate) else { return nil }
        let track = detector.track(in: range)
        let duration = range.upperBound - range.lowerBound
        let provisional = SwingAnalysisResult(pose: track, duration: duration, frameRate: frameRate, videoAspect: videoAspect)
        return LiveShot(shot: Shot(range: range, swing: candidate), provisional: provisional)
    }
}
