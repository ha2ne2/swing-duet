import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// 解析レートに間引いた 1 フレームの追跡結果（正規化座標・左下原点）
struct PoseFrame {
    var time: Double
    /// 手首（両手首の中点相当）。検出できなければ nil
    var wrist: CGPoint?
    /// 腰（root）。手の高さの基準（0）
    var root: CGPoint?
    /// 首（neck）。腰からの距離が体の大きさの単位
    var neck: CGPoint?
    /// 見えていた関節すべてを囲む矩形。人物を検出できなければ nil
    var bodyBounds: CGRect?
}

/// 人物の追跡結果
struct PoseTrack {
    var frames: [PoseFrame]

    /// 手首を検出できたフレームの割合
    var coverage: Double {
        frames.isEmpty ? 0 : Double(frames.filter { $0.wrist != nil }.count) / Double(frames.count)
    }

    /// 体の大きさ（腰から首までの高さ）。動画全体の中央値なので 1 フレームの外れ値に揺れない。
    /// 腰と首が同時に取れたフレームが無ければ nil（検出できない）
    var torsoHeight: Double? {
        let heights = frames.compactMap { frame -> Double? in
            guard let root = frame.root, let neck = frame.neck else { return nil }
            return abs(Double(neck.y - root.y))
        }
        return heights.median.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// 調査用（`analyze-swing --joints`）：追跡対象の人物の主要関節の生の位置と信頼度
struct JointFrame {
    var time: Double
    var joints: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
}

/// Vision の人体姿勢推定で動画の人物を追跡し、フレームごとの手首・腰・首の位置と関節の外接矩形を得る。
/// 複数人が写る動画（2 視点の合成など）では、腰位置が前フレームに最も近い人物を追い続ける（初回は最も大きく写る人物）。
enum PoseTracker {

    /// 解析レート（この頻度まで間引いて Vision を実行する）
    private static let sampleRate: Double = 30.0
    /// 関節の信頼度がこれ未満なら見えていない扱いにする
    private static let minJointConfidence: Float = 0.3
    /// 手首だけは、直前のフレームから続いている（`continuingDistance` 以内）ならこの信頼度でも採用する。
    /// 後方視点では手首が体の陰に入りかけて 0.1〜0.2 になるが位置は妥当なことが多く、欠測を縮められる
    private static let continuingConfidence: Float = 0.15
    private static let continuingDistance: CGFloat = 0.1

    static func track(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        frameRate: Double,
        orientation: CGImagePropertyOrientation
    ) throws -> PoseTrack {
        var frames: [PoseFrame] = []
        var wrists = WristTracker()
        try forEachTrackedPerson(asset: asset, videoTrack: videoTrack, frameRate: frameRate, orientation: orientation) { time, person in
            frames.append(PoseFrame(
                time: time,
                wrist: wrists.update(with: person),
                root: person.flatMap { location(of: .root, in: $0) },
                neck: person.flatMap { location(of: .neck, in: $0) },
                bodyBounds: person.flatMap { jointBounds(of: $0) }))
        }
        medianFilterWrists(&frames)
        return PoseTrack(frames: frames)
    }

    /// 調査用：追跡対象の人物の左右手首・腰・首を、信頼度による足切りをせずそのまま返す
    static func jointDump(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        frameRate: Double,
        orientation: CGImagePropertyOrientation
    ) throws -> [JointFrame] {
        let names: [VNHumanBodyPoseObservation.JointName] = [.leftWrist, .rightWrist, .root, .neck]
        var frames: [JointFrame] = []
        try forEachTrackedPerson(asset: asset, videoTrack: videoTrack, frameRate: frameRate, orientation: orientation) { time, person in
            var joints: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint] = [:]
            for name in names {
                if let point = try? person?.recognizedPoint(name) { joints[name] = point }
            }
            frames.append(JointFrame(time: time, joints: joints))
        }
        return frames
    }

    /// 動画の回転メタデータ（preferredTransform）を Vision に渡す向きに直す
    static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return .down }
        return .up
    }

    // MARK: - フレームの読み出しと人物の追跡

    /// 解析レートに間引いたフレームごとに、追跡対象の人物（見つからなければ nil）を時刻とともに渡す
    private static func forEachTrackedPerson(
        asset: AVURLAsset, videoTrack: AVAssetTrack, frameRate: Double, orientation: CGImagePropertyOrientation,
        _ body: (Double, VNHumanBodyPoseObservation?) -> Void
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SwingAnalyzerError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw SwingAnalyzerError.readerFailed }

        let request = VNDetectHumanBodyPoseRequest()
        let stride = max(1, Int((frameRate / sampleRate).rounded()))
        var frameIndex = 0
        var bodyAnchor: CGPoint? = nil   // 追跡中の人物の腰位置。複数人が写る動画で同じ人物を追い続けるために使う
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { frameIndex += 1 }
            if frameIndex % stride != 0 { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            autoreleasepool {
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
                var person: VNHumanBodyPoseObservation? = nil
                if (try? handler.perform([request])) != nil {
                    person = selectPerson(request.results ?? [], near: bodyAnchor)
                }
                if let person { bodyAnchor = anchor(of: person) ?? bodyAnchor }
                body(CMSampleBufferGetPresentationTimeStamp(sample).seconds, person)
            }
        }
        if reader.status == .failed {
            throw SwingAnalyzerError.readerFailed
        }
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

    // MARK: - 関節

    /// 手首点（両手首の中点相当）を、片方の手首しか見えないフレームでも飛ばずに続ける。
    /// 「中点 ↔ 片手」の切り替わりは 1 フレームで 0.05〜0.2 飛び、偽の速度になる（後方視点で頻発）
    private struct WristTracker {
        /// 直前のフレームで採用した点（見えなかったフレームの次は nil。信頼度の低い手首を続きとして採用する判定に使う）
        private var previous: CGPoint?
        /// 直前に両手首が見えたときの、各手首から中点へのベクトル。片方だけのときに足して中点相当にする
        private var leftToMid = CGPoint.zero
        private var rightToMid = CGPoint.zero

        mutating func update(with person: VNHumanBodyPoseObservation?) -> CGPoint? {
            let left = person.flatMap { wrist(.leftWrist, in: $0) }
            let right = person.flatMap { wrist(.rightWrist, in: $0) }
            let point: CGPoint?
            switch (left, right) {
            case let (left?, right?):
                let mid = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
                leftToMid = CGPoint(x: mid.x - left.x, y: mid.y - left.y)
                rightToMid = CGPoint(x: mid.x - right.x, y: mid.y - right.y)
                point = mid
            case let (left?, nil):
                point = CGPoint(x: left.x + leftToMid.x, y: left.y + leftToMid.y)
            case let (nil, right?):
                point = CGPoint(x: right.x + rightToMid.x, y: right.y + rightToMid.y)
            case (nil, nil):
                point = nil
            }
            previous = point
            return point
        }

        /// 手首の位置。通常の信頼度に届かなくても、直前の点の近くで続いていれば採用する
        private func wrist(_ joint: VNHumanBodyPoseObservation.JointName, in observation: VNHumanBodyPoseObservation) -> CGPoint? {
            guard let point = try? observation.recognizedPoint(joint) else { return nil }
            if point.confidence >= minJointConfidence { return point.location }
            if point.confidence >= continuingConfidence, let previous,
               point.location.distance(to: previous) <= continuingDistance {
                return point.location
            }
            return nil
        }
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

    /// 手首の単発の外れ値（誤検出の瞬間的な飛びなど）を抑える 3 点メディアン
    private static func medianFilterWrists(_ frames: inout [PoseFrame]) {
        guard frames.count >= 3 else { return }
        let wrists = frames.map(\.wrist)
        for i in 1..<(wrists.count - 1) {
            guard let a = wrists[i - 1], let b = wrists[i], let c = wrists[i + 1] else { continue }
            frames[i].wrist = CGPoint(x: [a.x, b.x, c.x].sorted()[1], y: [a.y, b.y, c.y].sorted()[1])
        }
    }
}
