import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// 自動検出の結果
struct SwingAnalysisResult {
    var phases: PhaseSet
    var lowConfidence: Bool
    var duration: Double
    var frameRate: Double
}

enum SwingAnalyzerError: LocalizedError {
    case noVideoTrack
    case readerFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "動画トラックが見つかりませんでした。"
        case .readerFailed: return "動画の読み込みに失敗しました。"
        }
    }
}

/// Vision の人体姿勢推定で手首を追跡し、手首速度からスイング区間とフェーズを検出する。
///
/// - トップ: 手首速度が最小になる点（インパクト直前の低速領域）
/// - インパクト: 手首速度が最大になる点
/// - アドレス / フィニッシュ: 前後の静止（低速が継続する区間）
enum SwingAnalyzer {

    /// 解析レート（この頻度まで間引いて Vision を実行する）
    private static let targetSampleRate: Double = 30.0

    static func analyze(url: URL) async throws -> SwingAnalysisResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SwingAnalyzerError.noVideoTrack
        }
        let fps = Double(try await track.load(.nominalFrameRate))
        let transform = try await track.load(.preferredTransform)
        let orientation = Self.orientation(from: transform)

        let (times, points, processedCount) = try Self.trackWrists(
            asset: asset, track: track, frameRate: fps, orientation: orientation)

        let coverage = processedCount > 0 ? Double(points.compactMap { $0 }.count) / Double(processedCount) : 0

        let (times2, speeds) = Self.speedSeries(times: times, points: points)
        let (detectedPhases, detected) = Self.detectPhases(times: times2, speeds: speeds, duration: duration)
        var phases = detectedPhases
        phases.sanitize(duration: duration)

        let lowConfidence = !detected || coverage < 0.4
        return SwingAnalysisResult(
            phases: phases,
            lowConfidence: lowConfidence,
            duration: duration,
            frameRate: fps > 1 ? fps : 30)
    }

    // MARK: - 手首追跡

    private static func trackWrists(
        asset: AVURLAsset,
        track: AVAssetTrack,
        frameRate: Double,
        orientation: CGImagePropertyOrientation
    ) throws -> (times: [Double], points: [CGPoint?], processed: Int) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SwingAnalyzerError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw SwingAnalyzerError.readerFailed }

        let stride = max(1, Int((frameRate / targetSampleRate).rounded()))
        let request = VNDetectHumanBodyPoseRequest()

        var times: [Double] = []
        var points: [CGPoint?] = []
        var frameIndex = 0
        var processed = 0

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { frameIndex += 1 }
            if frameIndex % stride != 0 { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            processed += 1

            autoreleasepool {
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
                var wrist: CGPoint? = nil
                if (try? handler.perform([request])) != nil,
                   let observation = request.results?.first {
                    wrist = Self.wristPoint(from: observation)
                }
                times.append(time)
                points.append(wrist)
            }
        }

        if reader.status == .failed {
            throw SwingAnalyzerError.readerFailed
        }
        return (times, points, processed)
    }

    private static func wristPoint(from observation: VNHumanBodyPoseObservation) -> CGPoint? {
        let minConfidence: Float = 0.3
        let left = try? observation.recognizedPoint(.leftWrist)
        let right = try? observation.recognizedPoint(.rightWrist)
        let validLeft = (left?.confidence ?? 0) >= minConfidence ? left : nil
        let validRight = (right?.confidence ?? 0) >= minConfidence ? right : nil

        switch (validLeft, validRight) {
        case let (l?, r?):
            return CGPoint(x: (l.location.x + r.location.x) / 2,
                           y: (l.location.y + r.location.y) / 2)
        case let (l?, nil):
            return l.location
        case let (nil, r?):
            return r.location
        default:
            return nil
        }
    }

    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return .down }
        return .up
    }

    // MARK: - 速度系列

    /// 正規化座標での手首速度（単位: 正規化距離/秒）。移動平均で平滑化する。
    private static func speedSeries(
        times: [Double], points: [CGPoint?]
    ) -> (times: [Double], speeds: [Double]) {
        var outTimes: [Double] = []
        var raw: [Double] = []

        var lastTime: Double? = nil
        var lastPoint: CGPoint? = nil
        for (t, p) in zip(times, points) {
            guard let p else { continue }
            if let lt = lastTime, let lp = lastPoint, t - lt > 0, t - lt < 0.25 {
                let dx = p.x - lp.x
                let dy = p.y - lp.y
                let v = Double(hypot(dx, dy)) / (t - lt)
                outTimes.append(t)
                raw.append(v)
            }
            lastTime = t
            lastPoint = p
        }

        // 移動平均（窓5）
        guard raw.count > 4 else { return (outTimes, raw) }
        var smoothed = raw
        let half = 2
        for i in raw.indices {
            let lo = max(0, i - half)
            let hi = min(raw.count - 1, i + half)
            smoothed[i] = raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        return (outTimes, smoothed)
    }

    // MARK: - フェーズ検出

    /// 戻り値の Bool は検出成功フラグ（false = フォールバック値）
    static func detectPhases(
        times: [Double], speeds: [Double], duration: Double
    ) -> (PhaseSet, Bool) {
        guard speeds.count >= 8,
              let maxV = speeds.max(), maxV > 0,
              let impactIdx = speeds.firstIndex(of: maxV) else {
            return (PhaseSet.fallback(duration: duration), false)
        }

        let stillThreshold = 0.10 * maxV
        let lowThreshold = 0.20 * maxV

        // --- トップ ---
        // インパクトから遡り、速度が低い領域（切り返し）に入るまで戻る
        var i = impactIdx
        while i > 0 && speeds[i] >= lowThreshold { i -= 1 }
        guard i > 0 else {
            return (PhaseSet.fallback(duration: duration), false)
        }
        // 低速領域内の最小値がトップ
        var j = i
        var topIdx = i
        while j > 0 && speeds[j] < lowThreshold {
            if speeds[j] < speeds[topIdx] { topIdx = j }
            j -= 1
        }

        // --- アドレス ---
        // トップ手前のバックスイング動作をさらに遡り、静止が続く点を探す
        var addressIdx = 0
        var k = j
        var passedBackswing = false
        while k > 0 {
            if speeds[k] >= lowThreshold { passedBackswing = true }
            if passedBackswing && speeds[k] < stillThreshold
                && isSustained(speeds, times, around: k, below: stillThreshold, window: 0.15, forward: false) {
                addressIdx = k
                break
            }
            k -= 1
        }

        // --- フィニッシュ ---
        var finishIdx = speeds.count - 1
        var m = impactIdx
        while m < speeds.count - 1 {
            if speeds[m] < stillThreshold
                && isSustained(speeds, times, around: m, below: stillThreshold, window: 0.2, forward: true) {
                finishIdx = m
                break
            }
            m += 1
        }

        let address = max(0, times[addressIdx] - 0.1)
        let top = times[topIdx]
        let impact = times[impactIdx]
        let finish = min(duration, times[finishIdx] + 0.2)

        var phases = PhaseSet(address: address, top: top, impact: impact, finish: finish)
        // 最低限の妥当性（順序が概ね取れているか）
        guard top > address, impact > top, finish > impact else {
            return (PhaseSet.fallback(duration: duration), false)
        }
        phases.sanitize(duration: duration)
        return (phases, true)
    }

    /// idx の前後 window 秒にわたって threshold 未満が継続しているか
    private static func isSustained(
        _ speeds: [Double], _ times: [Double],
        around idx: Int, below threshold: Double, window: Double, forward: Bool
    ) -> Bool {
        let t0 = times[idx]
        if forward {
            var i = idx
            while i < speeds.count && times[i] - t0 <= window {
                if speeds[i] >= threshold { return false }
                i += 1
            }
        } else {
            var i = idx
            while i >= 0 && t0 - times[i] <= window {
                if speeds[i] >= threshold { return false }
                i -= 1
            }
        }
        return true
    }
}
