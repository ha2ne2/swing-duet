import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// 自動検出の結果（動画 1 本分）
struct SwingAnalysisResult {
    var duration: Double
    var frameRate: Double
    /// 手首の追跡結果
    var wrists: WristTrack
    /// 動画内で見つかったスイング候補（時系列順・採点済み。素振りを含む）。検出失敗時は空
    var candidates: [SwingCandidate]

    /// 採用するスイング（最も「振り切っている」候補）。検出失敗時は nil
    var chosen: SwingCandidate? { candidates.max { $0.score < $1.score } }

    /// 採用したスイングのフェーズ。検出失敗時はフォールバック値
    var phases: PhaseSet { chosen?.phases ?? .fallback(duration: duration) }

    /// 手動確認を促すべきか：検出失敗、手首の検出率 40% 未満、採用スイングの切り返し〜インパクトが未観測のとき
    var lowConfidence: Bool {
        guard let chosen else { return true }
        return wrists.coverage < 0.4 || chosen.downswingUnobserved
    }

    /// 取り込んだ動画の設定を作る（表示変換は初期値）
    func videoConfig(fileName: String) -> VideoConfig {
        VideoConfig(
            fileName: fileName,
            duration: duration,
            frameRate: frameRate,
            phases: phases,
            lowConfidence: lowConfidence,
            candidates: candidates.map(\.phases))
    }
}

/// 手首の追跡結果（解析レートに間引いたフレームごと）
struct WristTrack {
    /// 各フレームの時刻（秒）
    var times: [Double]
    /// 各フレームの手首位置（正規化座標・左下原点）。検出できなかったフレームは nil
    var points: [CGPoint?]

    /// 手首を検出できたフレームの割合
    var coverage: Double {
        points.isEmpty ? 0 : Double(points.filter { $0 != nil }.count) / Double(points.count)
    }
}

/// 手首速度の 1 サンプル
struct SpeedSample {
    var time: Double
    /// 平滑化した速度（正規化距離/秒）
    var speed: Double
    /// その時刻の手首位置
    var point: CGPoint
}

/// 1 回のスイング候補（採点の内訳付き）
struct SwingCandidate {
    var phases: PhaseSet
    /// 区間内の最大手首速度
    var peakSpeed: Double
    /// アドレス位置からトップまでの手首の移動量（正規化距離）
    var backswingSpan: Double
    /// インパクトからフィニッシュまでの手首の移動量（正規化距離）
    var followSpan: Double
    /// トップからインパクトの間で手首を見失っていた最長時間（秒）
    var downswingGap: Double
    /// 「振り切り度」。大きいほど本番スイングらしい（候補の中での相対値。最良の候補が約 1.0）
    var score: Double = 0

    /// 手の移動量（バックスイング + フォロー）
    var travel: Double { backswingSpan + followSpan }

    /// 切り返し〜インパクトがブレで観測できていない。30fps では速い動きで手首を見失いやすく、
    /// そのときのトップ・インパクトは欠測の両端に置かれるので位置が粗い（手動確認を促す）
    var downswingUnobserved: Bool { downswingGap >= 0.2 }
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

/// Vision の人体姿勢推定で手首を追跡し、手首の動きからスイング区間とフェーズを検出する。
///
/// 1 本の動画に素振りなど複数のスイングが写っていることを前提に、動作区間ごとにフェーズを求め、
/// 最も「振り切っている」スイングを採用する（候補はすべて返し、ユーザーが選び直せる）。
///
/// 各スイングのフェーズは、手首とアドレス位置との距離の形で決める：
/// - アドレス: 動作区間の手前で静止が続く点
/// - トップ: 手首がアドレス位置から最も離れた点（折り返し）
/// - インパクト: トップの後、手首がアドレス位置に最も近づく点（通過）
/// - フィニッシュ: インパクトの後に静止が続く点
/// 速度の最大値をインパクトとみなさないのは、30fps ではインパクト前後がブレて手首を見失うことが多く、
/// 観測できた最大速度がフォロー側にずれるため。
enum SwingAnalyzer {

    /// 解析レート（この頻度まで間引いて Vision を実行する）
    private static let targetSampleRate: Double = 30.0
    /// 関節の信頼度がこれ未満なら見えていない扱いにする
    private static let minJointConfidence: Float = 0.3

    static func analyze(url: URL) async throws -> SwingAnalysisResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SwingAnalyzerError.noVideoTrack
        }
        let fps = Double(try await track.load(.nominalFrameRate))
        let transform = try await track.load(.preferredTransform)

        let wrists = try trackWrists(asset: asset, track: track, frameRate: fps, orientation: orientation(from: transform))
        return SwingAnalysisResult(
            duration: duration,
            frameRate: fps > 1 ? fps : 30,
            wrists: wrists,
            candidates: detectSwings(track: wrists, duration: duration))
    }

    // MARK: - 手首追跡

    private static func trackWrists(
        asset: AVURLAsset,
        track: AVAssetTrack,
        frameRate: Double,
        orientation: CGImagePropertyOrientation
    ) throws -> WristTrack {
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
        // 追跡中の人物の腰位置。複数人が写る動画（2 視点の合成など）で同じ人物を追い続けるために使う
        var bodyAnchor: CGPoint? = nil

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { frameIndex += 1 }
            if frameIndex % stride != 0 { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            autoreleasepool {
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
                var wrist: CGPoint? = nil
                if (try? handler.perform([request])) != nil,
                   let person = selectPerson(request.results ?? [], near: bodyAnchor) {
                    bodyAnchor = anchor(of: person) ?? bodyAnchor
                    wrist = wristPoint(from: person)
                }
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                points.append(wrist)
            }
        }

        if reader.status == .failed {
            throw SwingAnalyzerError.readerFailed
        }
        return WristTrack(times: times, points: medianFiltered(points))
    }

    /// 追跡対象の人物を選ぶ。初回は最も大きく写っている人物、以降は腰位置が前フレームに最も近い人物
    /// （離れすぎていれば見失い扱いで nil）
    private static func selectPerson(
        _ observations: [VNHumanBodyPoseObservation], near tracked: CGPoint?
    ) -> VNHumanBodyPoseObservation? {
        guard let tracked else {
            return observations.max { bodySize(of: $0) < bodySize(of: $1) }
        }
        let maxJump: CGFloat = 0.2   // 腰は 1 フレームでこれ以上動かない（正規化距離）
        let distances = observations.compactMap { observation in
            anchor(of: observation).map { (observation, $0.distance(to: tracked)) }
        }
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= maxJump else { return nil }
        return nearest.0
    }

    /// 人物の位置の代表点（腰。取れなければ首）
    private static func anchor(of observation: VNHumanBodyPoseObservation) -> CGPoint? {
        location(of: .root, in: observation) ?? location(of: .neck, in: observation)
    }

    /// 写っている大きさの目安（首〜腰の長さ）
    private static func bodySize(of observation: VNHumanBodyPoseObservation) -> CGFloat {
        guard let root = location(of: .root, in: observation),
              let neck = location(of: .neck, in: observation) else { return 0 }
        return neck.distance(to: root)
    }

    /// 両手首の中点（片方しか見えなければその位置）
    private static func wristPoint(from observation: VNHumanBodyPoseObservation) -> CGPoint? {
        let left = location(of: .leftWrist, in: observation)
        let right = location(of: .rightWrist, in: observation)
        if let left, let right {
            return CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        }
        return left ?? right
    }

    /// 関節の位置。信頼度が minJointConfidence 未満なら nil
    private static func location(
        of joint: VNHumanBodyPoseObservation.JointName, in observation: VNHumanBodyPoseObservation
    ) -> CGPoint? {
        guard let point = try? observation.recognizedPoint(joint), point.confidence >= minJointConfidence else {
            return nil
        }
        return point.location
    }

    /// 単発の外れ値（片手首だけになった瞬間の位置の飛びなど）を抑える 3 点メディアン
    private static func medianFiltered(_ points: [CGPoint?]) -> [CGPoint?] {
        guard points.count >= 3 else { return points }
        var result = points
        for i in 1..<(points.count - 1) {
            guard let a = points[i - 1], let b = points[i], let c = points[i + 1] else { continue }
            result[i] = CGPoint(x: [a.x, b.x, c.x].sorted()[1], y: [a.y, b.y, c.y].sorted()[1])
        }
        return result
    }

    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return .down }
        return .up
    }

    // MARK: - 速度系列

    /// 手首速度の系列（単位: 正規化距離/秒）。移動平均（窓 5）で平滑化する。
    /// 検出できないフレームは飛ばし、直前の検出から 0.25 秒以上あいたサンプル（ブレで見失った直後）の速度は作らない
    static func speedSeries(track: WristTrack) -> [SpeedSample] {
        var samples: [SpeedSample] = []
        var last: (time: Double, point: CGPoint)? = nil
        for (t, p) in zip(track.times, track.points) {
            guard let p else { continue }
            if let last, t - last.time > 0, t - last.time < 0.25 {
                samples.append(SpeedSample(time: t, speed: Double(p.distance(to: last.point)) / (t - last.time), point: p))
            }
            last = (t, p)
        }

        let raw = samples.map(\.speed)
        let half = 2
        for i in raw.indices {
            let window = raw[max(0, i - half)...min(raw.count - 1, i + half)]
            samples[i].speed = window.reduce(0, +) / Double(window.count)
        }
        return samples
    }

    // MARK: - スイング検出

    /// 手首の追跡結果からスイング候補を作り、採点する（時系列順）。スイングが見つからなければ空
    static func detectSwings(track: WristTrack, duration: Double) -> [SwingCandidate] {
        let samples = speedSeries(track: track)
        guard samples.count >= 8, let maxSpeed = samples.map(\.speed).max(), maxSpeed > 0 else { return [] }

        let segments = motionSegments(samples, threshold: 0.20 * maxSpeed)
        var candidates: [SwingCandidate] = []
        for (i, segment) in segments.enumerated() {
            // アドレス・フィニッシュを探してよい範囲。隣の区間がある側はそのサンプル時刻まで、無い側は動画の端まで
            let lowerBound = i > 0 ? segments[i - 1].end + 1 : 0
            let upperBound = i + 1 < segments.count ? segments[i + 1].start - 1 : samples.count - 1
            let lowerTime = i > 0 ? samples[lowerBound].time : 0
            let upperTime = i + 1 < segments.count ? samples[upperBound].time : duration
            if let candidate = swingCandidate(
                in: segment, samples: samples, searchRange: lowerBound...upperBound, timeBounds: lowerTime...upperTime,
                stillThreshold: 0.10 * maxSpeed, duration: duration) {
                candidates.append(candidate)
            }
        }

        // 採点：手の移動量とピーク速度（候補内の最大で正規化）。同程度なら後のスイング（本番は素振りの後）
        let maxTravel = candidates.map(\.travel).max() ?? 1
        let maxPeak = candidates.map(\.peakSpeed).max() ?? 1
        for i in candidates.indices {
            let order = candidates.count > 1 ? Double(i) / Double(candidates.count - 1) : 0
            candidates[i].score = 0.5 * candidates[i].travel / maxTravel + 0.5 * candidates[i].peakSpeed / maxPeak + 0.03 * order
        }
        return candidates
    }

    /// 速度サンプルの添字で表した動作区間（両端を含む）
    struct Segment {
        var start: Int
        var end: Int
    }

    /// 速度が threshold 以上の区間を「1 回のスイング動作」としてまとめる。
    /// 切り返しの一瞬の減速で分断しないよう、低速サンプルの連なりが pauseMax 秒未満なら同じ区間に含める。
    /// 追跡が途切れた時間帯（速い動きでブレて検出できない）には低速サンプルが無いので、自然に同じ区間になる。
    static func motionSegments(_ samples: [SpeedSample], threshold: Double, pauseMax: Double = 0.6) -> [Segment] {
        let frameInterval = 1.0 / targetSampleRate
        var segments: [Segment] = []
        var pauseStart: Int? = nil   // 直近の区間の後に続いている低速サンプルの先頭
        for i in samples.indices {
            guard samples[i].speed >= threshold else {
                if !segments.isEmpty, pauseStart == nil { pauseStart = i }
                continue
            }
            // 直前の低速サンプルの連なり（pauseStart 〜 i - 1）の長さ
            let pause = pauseStart.map { samples[i - 1].time - samples[$0].time + frameInterval } ?? 0
            if segments.isEmpty || pause >= pauseMax {
                segments.append(Segment(start: i, end: i))
            } else {
                segments[segments.count - 1].end = i
            }
            pauseStart = nil
        }
        return segments
    }

    /// 動作区間からスイング候補を作る。searchRange / timeBounds はアドレス・フィニッシュを探してよい範囲（隣の区間に踏み込まない）。
    /// スイングと呼べる動きが無ければ nil
    private static func swingCandidate(
        in segment: Segment,
        samples: [SpeedSample],
        searchRange: ClosedRange<Int>,
        timeBounds: ClosedRange<Double>,
        stillThreshold: Double,
        duration: Double
    ) -> SwingCandidate? {
        let minBackswingSpan = 0.08   // これより小さい動きはワッグルや揺れ

        // --- アドレス：区間の手前で静止が 0.15 秒続く点（無ければ区間の先頭） ---
        let addressIdx = stride(from: segment.start - 1, through: searchRange.lowerBound, by: -1)
            .first { isStill(samples, from: $0, toward: searchRange.lowerBound, window: 0.15, below: stillThreshold) }
            ?? segment.start
        let addressPoint = samples[addressIdx].point
        func distance(_ i: Int) -> Double { Double(samples[i].point.distance(to: addressPoint)) }

        // --- トップとインパクト：アドレス位置から離れて（トップ）、戻って最も近づき（インパクト）、また離れていく ---
        var topIdx = segment.start
        var topDistance = 0.0
        var impactIdx: Int? = nil
        var impactDistance = Double.infinity
        for i in segment.start...segment.end {
            let d = distance(i)
            if impactIdx == nil {
                if d > topDistance {
                    topDistance = d
                    topIdx = i
                } else if topDistance >= minBackswingSpan && d < 0.5 * topDistance {
                    impactIdx = i          // 折り返して半分以上戻った → ここからインパクトを探す
                    impactDistance = d
                }
            } else if d < impactDistance {
                impactDistance = d
                impactIdx = i
            } else if d > impactDistance + 0.5 * topDistance {
                break                      // フォローで再び離れ始めた
            }
        }
        guard let impactIdx else { return nil }

        // --- フィニッシュ：インパクトの後で静止が 0.2 秒続く点（無ければ区間の末尾） ---
        let finishIdx = stride(from: impactIdx + 1, through: searchRange.upperBound, by: 1)
            .first { isStill(samples, from: $0, toward: searchRange.upperBound, window: 0.2, below: stillThreshold) }
            ?? segment.end

        var phases = PhaseSet(
            address: max(timeBounds.lowerBound, samples[addressIdx].time - 0.1),
            top: samples[topIdx].time,
            impact: samples[impactIdx].time,
            finish: min(timeBounds.upperBound, samples[finishIdx].time + 0.2))
        guard phases.top > phases.address, phases.impact > phases.top, phases.finish > phases.impact else { return nil }
        phases.sanitize(duration: duration)

        return SwingCandidate(
            phases: phases,
            peakSpeed: samples[segment.start...segment.end].map(\.speed).max() ?? 0,
            backswingSpan: topDistance,
            followSpan: Double(samples[finishIdx].point.distance(to: samples[impactIdx].point)),
            downswingGap: stride(from: topIdx, to: impactIdx, by: 1).map { samples[$0 + 1].time - samples[$0].time }.max() ?? 0)
    }

    /// idx から bound の方向へ window 秒にわたって速度が threshold 未満（静止）が続いているか。bound を越えては見ない
    private static func isStill(
        _ samples: [SpeedSample], from idx: Int, toward bound: Int, window: Double, below threshold: Double
    ) -> Bool {
        stride(from: idx, through: bound, by: bound >= idx ? 1 : -1)
            .prefix { abs(samples[$0].time - samples[idx].time) <= window }
            .allSatisfy { samples[$0].speed < threshold }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
