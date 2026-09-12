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

/// Vision の人体姿勢推定で動画の人物を追跡し、フレームごとの手首・腰・首の位置と関節の外接矩形を得る。
/// 複数人が写る動画（2 視点の合成など）では、腰位置が前フレームに最も近い人物を追い続ける（初回は最も大きく写る人物）。
/// 動画ファイルは `track(asset:...)` で読む。撮影中のフレームを 1 枚ずつ渡すときは `FrameTracker` を直接使う
enum PoseTracker {

    /// 解析レート（この頻度まで間引いて Vision を実行する）
    static let sampleRate: Double = 30.0
    /// 関節の信頼度がこれ未満なら見えていない扱いにする
    private static let minJointConfidence: Float = 0.3
    /// 手首だけは、直前のフレームから続いている（`continuingDistance` 以内）ならこの信頼度でも採用する。
    /// 後方視点では手首が体の陰に入りかけて 0.1〜0.2 になるが位置は妥当なことが多く、欠測を縮められる
    private static let continuingConfidence: Float = 0.15
    private static let continuingDistance: CGFloat = 0.1

    static func track(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        frameRate: Double,
        orientation: CGImagePropertyOrientation
    ) throws -> PoseTrack {
        var tracker = FrameTracker()
        var frames: [PoseFrame] = []
        try forEachSampledFrame(asset: asset, videoTrack: videoTrack, frameRate: frameRate) { time, pixelBuffer in
            let person = tracker.person(in: pixelBuffer, orientation: orientation)
            frames.append(tracker.frame(at: time, person: person))
        }
        return PoseTrack(frames: medianFilteredWrists(frames))
    }

    /// 動画の回転メタデータ（preferredTransform）を Vision に渡す向きに直す
    static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return .down }
        return .up
    }

    // MARK: - フレーム 1 枚ずつの追跡

    /// フレームを 1 枚ずつ受け取って同じ人物を追い続ける状態（人物の選択と、片手しか見えないときの手首の続き）。
    /// 動画ファイルの読み出しでも撮影中のフレームでも同じ
    struct FrameTracker {
        /// 追跡中の人物を 1 秒（解析レート分のフレーム）続けて見失ったら、腰位置のアンカーを捨てて最も大きく写る人物を選び直す。
        /// 長回しでは人物が球を取りに行って戻る・最初に別のものを掴むことがあり、捨てないと二度と追い直せない
        private static let reacquireAfterMisses = Int(PoseTracker.sampleRate)

        private let request = VNDetectHumanBodyPoseRequest()
        /// 追跡中の人物の腰位置。複数人が写る動画で同じ人物を追い続けるために使う
        private var bodyAnchor: CGPoint?
        private var misses = 0
        private var wrists = WristTracker()

        init() {}

        /// このフレームの追跡対象の人物（見つからなければ nil）
        mutating func person(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> VNHumanBodyPoseObservation? {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            guard (try? handler.perform([request])) != nil else { return nil }
            let person = selectPerson(request.results ?? [], near: bodyAnchor)
            if let person {
                bodyAnchor = anchor(of: person) ?? bodyAnchor
                misses = 0
            } else {
                misses += 1
                if misses >= Self.reacquireAfterMisses { bodyAnchor = nil }
            }
            return person
        }

        /// 追跡対象の人物からフレーム 1 枚の結果を作る（人物が見つからなかったフレームも、手首の続きを切るために渡す）
        mutating func frame(at time: Double, person: VNHumanBodyPoseObservation?) -> PoseFrame {
            PoseFrame(
                time: time,
                wrist: wrists.update(with: person),
                root: person.flatMap { location(of: .root, in: $0) },
                neck: person.flatMap { location(of: .neck, in: $0) },
                bodyBounds: person.flatMap { jointBounds(of: $0) })
        }
    }

    // MARK: - 動画ファイルの読み出し

    /// 解析レートに間引いたフレームを時刻とともに渡す。
    /// 解析 CLI（scripts/analyze-swing）の関節ダンプからも使うので private にしない
    static func forEachSampledFrame(
        asset: AVAsset, videoTrack: AVAssetTrack, frameRate: Double,
        _ body: (Double, CVPixelBuffer) -> Void
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw VideoError.unreadable }

        let stride = max(1, Int((frameRate / sampleRate).rounded()))
        var frameIndex = 0
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { frameIndex += 1 }
            if frameIndex % stride != 0 { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            autoreleasepool {
                body(CMSampleBufferGetPresentationTimeStamp(sample).seconds, pixelBuffer)
            }
        }
        if reader.status == .failed {
            throw VideoError.unreadable
        }
    }

    /// 追跡対象の人物を選ぶ。初回（アンカー無し）は最も大きく写っている人物、以降は腰位置が前フレームに最も近い人物
    /// （離れすぎていれば見失い扱いで nil）。腰と首の両方が見えている人物がいなければ選ばない（体の大きさが測れない観測を掴むと、
    /// そのアンカーに引きずられて本当の人物を追えなくなる）
    private static func selectPerson(
        _ observations: [VNHumanBodyPoseObservation], near tracked: CGPoint?
    ) -> VNHumanBodyPoseObservation? {
        guard let tracked else {
            guard let largest = observations.max(by: { bodySize(of: $0) < bodySize(of: $1) }), bodySize(of: largest) > 0 else { return nil }
            return largest
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
    private static func medianFilteredWrists(_ frames: [PoseFrame]) -> [PoseFrame] {
        guard frames.count >= 3 else { return frames }
        var filtered = frames
        let wrists = frames.map(\.wrist)
        for i in 1..<(wrists.count - 1) {
            guard let a = wrists[i - 1], let b = wrists[i], let c = wrists[i + 1] else { continue }
            filtered[i].wrist = CGPoint(x: [a.x, b.x, c.x].sorted()[1], y: [a.y, b.y, c.y].sorted()[1])
        }
        return filtered
    }
}
