import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// 人物の追跡結果（解析レートに間引いたフレームごとの手首位置と、関節の外接矩形）
struct PoseTrack {
    /// 各フレームの時刻（秒）
    var times: [Double]
    /// 各フレームの手首位置（正規化座標・左下原点）。検出できなかったフレームは nil
    var points: [CGPoint?]
    /// 各フレームで見えていた関節すべてを囲む矩形（正規化座標・左下原点）。人物を検出できなかったフレームは nil
    var bodyBounds: [CGRect?]

    /// 手首を検出できたフレームの割合
    var coverage: Double {
        points.isEmpty ? 0 : Double(points.filter { $0 != nil }.count) / Double(points.count)
    }
}

/// Vision の人体姿勢推定で動画の人物を追跡し、フレームごとの手首位置と関節の外接矩形を得る。
/// 複数人が写る動画（2 視点の合成など）では、腰位置が前フレームに最も近い人物を追い続ける（初回は最も大きく写る人物）。
enum PoseTracker {

    /// 解析レート（この頻度まで間引いて Vision を実行する）
    private static let sampleRate: Double = 30.0
    /// 関節の信頼度がこれ未満なら見えていない扱いにする
    private static let minJointConfidence: Float = 0.3

    static func track(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        frameRate: Double,
        orientation: CGImagePropertyOrientation
    ) throws -> PoseTrack {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SwingAnalyzerError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw SwingAnalyzerError.readerFailed }

        let stride = max(1, Int((frameRate / sampleRate).rounded()))
        let request = VNDetectHumanBodyPoseRequest()

        var times: [Double] = []
        var points: [CGPoint?] = []
        var bodyBounds: [CGRect?] = []
        var frameIndex = 0
        // 追跡中の人物の腰位置。複数人が写る動画で同じ人物を追い続けるために使う
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
                var body: CGRect? = nil
                if (try? handler.perform([request])) != nil,
                   let person = selectPerson(request.results ?? [], near: bodyAnchor) {
                    bodyAnchor = anchor(of: person) ?? bodyAnchor
                    wrist = wristPoint(from: person)
                    body = jointBounds(of: person)
                }
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                points.append(wrist)
                bodyBounds.append(body)
            }
        }

        if reader.status == .failed {
            throw SwingAnalyzerError.readerFailed
        }
        return PoseTrack(times: times, points: medianFiltered(points), bodyBounds: bodyBounds)
    }

    /// 動画の回転メタデータ（preferredTransform）を Vision に渡す向きに直す
    static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return .down }
        return .up
    }

    // MARK: - 人物の選択

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

    // MARK: - 関節

    /// 両手首の中点（片方しか見えなければその位置）
    private static func wristPoint(from observation: VNHumanBodyPoseObservation) -> CGPoint? {
        let left = location(of: .leftWrist, in: observation)
        let right = location(of: .rightWrist, in: observation)
        if let left, let right {
            return CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        }
        return left ?? right
    }

    /// 見えている関節すべてを囲む矩形（ペインの自動フィット用）。関節が 1 つも見えなければ nil
    private static func jointBounds(of observation: VNHumanBodyPoseObservation) -> CGRect? {
        guard let joints = try? observation.recognizedPoints(.all) else { return nil }
        return CGRect(enclosing: joints.values.filter { $0.confidence >= minJointConfidence }.map(\.location))
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
}
