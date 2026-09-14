import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// 解析レートに間引いた 1 フレームの追跡結果（正規化座標・左下原点）
struct PoseFrame {
    var time: Double
    /// 手首（両手首の中点相当）。検出できなければ nil
    var wrist: CGPoint? = nil
    /// 頭（鼻。後方視点で顔が見えないときは目・耳で代用）。軌跡の表示に使う
    var head: CGPoint? = nil
    /// 肩と股関節（左右。被写体から見た左右）。軌跡の表示に使う
    var leftShoulder: CGPoint? = nil
    var rightShoulder: CGPoint? = nil
    var leftHip: CGPoint? = nil
    var rightHip: CGPoint? = nil
    /// 腰（root）。手の高さの基準（0）
    var root: CGPoint? = nil
    /// 首（neck）。腰からの距離が体の大きさの単位
    var neck: CGPoint? = nil
    /// 見えていた関節すべてを囲む矩形。人物を検出できなければ nil
    var bodyBounds: CGRect? = nil
}

/// 人物の追跡結果
struct PoseTrack {
    var frames: [PoseFrame]

    /// 範囲の分だけを、先頭を 0 にずらして 1 本の動画として見た追跡結果。
    /// 長い動画から 1 球を切り出すとき（`SwingAnalysisResult.sliced`）と、撮影中に候補の範囲を仮の解析に掛けるとき（`LiveDetector.track`）に使う
    func sliced(to range: ClosedRange<Double>) -> PoseTrack {
        PoseTrack(frames: frames.filter { range.contains($0.time) }.map { frame in
            var shifted = frame
            shifted.time -= range.lowerBound
            return shifted
        })
    }

    /// 手首の単発の外れ値（誤検出の瞬間的な飛びなど）を 3 点メディアンで抑えたもの。
    /// 動画の追跡（`PoseTracker.track`）と撮影中の窓（`LiveDetector`）の両方で、検出に掛ける前に通す
    func medianFilteredWrists() -> PoseTrack {
        guard frames.count >= 3 else { return self }
        var filtered = frames
        let wrists = frames.map(\.wrist)
        for i in 1..<(wrists.count - 1) {
            guard let a = wrists[i - 1], let b = wrists[i], let c = wrists[i + 1] else { continue }
            filtered[i].wrist = CGPoint(x: [a.x, b.x, c.x].sorted()[1], y: [a.y, b.y, c.y].sorted()[1])
        }
        return PoseTrack(frames: filtered)
    }

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

/// Vision の人体姿勢推定で動画の人物を追跡し、フレームごとの手首・頭・肩・腰・首の位置と関節の外接矩形を得る。
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
        return PoseTrack(frames: frames).medianFilteredWrists()
    }

    /// 動画の回転メタデータ（preferredTransform）を Vision に渡す向きに直す。
    /// 成分は丸めて比べる（`CGAffineTransform(rotationAngle:)` で作った行列は cos(π/2) が厳密な 0 にならない。
    /// 厳密比較だと縦撮りを `.up` と読み、人物を横倒しのまま追跡して手の高さが壊れる）
    static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        let (a, b, c, d) = (Int(t.a.rounded()), Int(t.b.rounded()), Int(t.c.rounded()), Int(t.d.rounded()))
        if a == 0 && b == 1 && c == -1 && d == 0 { return .right }
        if a == 0 && b == -1 && c == 1 && d == 0 { return .left }
        if a == -1 && b == 0 && c == 0 && d == -1 { return .down }
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
        /// 追跡中の人物の大きさ（首〜腰）。近くに立つ別人へ乗り換えないための手掛かり
        private var trackedSize: CGFloat?
        private var misses = 0
        private var wrists = WristTracker()

        init() {}

        /// このフレームの追跡対象の人物（見つからなければ nil）
        mutating func person(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> VNHumanBodyPoseObservation? {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            guard (try? handler.perform([request])) != nil else { return nil }
            let aspect = shownAspect(
                width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), orientation: orientation)
            let person = selectPerson(request.results ?? [], near: bodyAnchor, size: trackedSize, aspect: aspect)
            if let person {
                bodyAnchor = anchor(of: person) ?? bodyAnchor
                trackedSize = bodySize(of: person)
                misses = 0
            } else {
                misses += 1
                if misses >= Self.reacquireAfterMisses {
                    bodyAnchor = nil
                    trackedSize = nil
                }
            }
            return person
        }

        /// 追跡対象の人物からフレーム 1 枚の結果を作る（人物が見つからなかったフレームも、手首の続きを切るために渡す）
        mutating func frame(at time: Double, person: VNHumanBodyPoseObservation?) -> PoseFrame {
            PoseFrame(
                time: time,
                wrist: wrists.update(with: person),
                head: person.flatMap { headLocation(in: $0) },
                leftShoulder: person.flatMap { location(of: .leftShoulder, in: $0) },
                rightShoulder: person.flatMap { location(of: .rightShoulder, in: $0) },
                leftHip: person.flatMap { location(of: .leftHip, in: $0) },
                rightHip: person.flatMap { location(of: .rightHip, in: $0) },
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

    /// 追跡対象の人物を選ぶ。候補は「胴体が縦向き」（`isUpright`）で、追跡中なら「大きさが前フレームに近い」観測に絞る。
    /// 初回（アンカー無し）は候補の中で最も大きく写っている人物、以降は腰位置が最も近い人物（離れすぎていれば見失い扱いで nil）
    private static func selectPerson(
        _ observations: [VNHumanBodyPoseObservation], near tracked: CGPoint?, size: CGFloat?, aspect: CGFloat
    ) -> VNHumanBodyPoseObservation? {
        // isUpright を通った観測は腰も首も見えているので、体の大きさは必ず 0 より大きい
        var candidates = observations.filter { isUpright($0, aspect: aspect) }
        guard let tracked else { return candidates.max(by: { bodySize(of: $0) < bodySize(of: $1) }) }

        // 大きさが 1 フレームで急に変わることはない（実測で 1 コマ 9〜16%）。腰の近さだけで選ぶと、観客が並ぶ中継映像で、
        // 追跡中のゴルファー（首〜腰 0.15）が一瞬とれなくなった隙に後ろの観客（0.09）へ乗り換えてしまう。
        // 合う候補が無いフレームは誰も選ばず、見失いとして本人が戻るのを待つ（1 秒戻らなければアンカーを捨てて選び直す）
        let maxSizeChange: CGFloat = 0.25
        if let size, size > 0 {
            candidates = candidates.filter { abs(bodySize(of: $0) / size - 1) <= maxSizeChange }
        }
        let maxJump: CGFloat = 0.2   // 腰は 1 フレームでこれ以上動かない（正規化距離）
        let distances = candidates.compactMap { observation in
            anchor(of: observation).map { (observation, $0.distance(to: tracked)) }
        }
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= maxJump else { return nil }
        return nearest.0
    }

    /// 胴体（腰 → 首）が縦向きか。観客が並ぶ映像では別々の人の関節をつないだ骨格が返ることがあり、それは腰と首が横に離れる。
    /// 首〜腰の長さで「最も大きく写っている人物」を選ぶとその骨格が勝ってしまうので、先に外す。
    /// 正規化座標は縦横で尺度が違うので、画面の縦横比を掛けて画素の比で比べる（縦長の動画では横の差が 1.8 倍に見える）
    private static func isUpright(_ observation: VNHumanBodyPoseObservation, aspect: CGFloat) -> Bool {
        guard let root = location(of: .root, in: observation), let neck = location(of: .neck, in: observation) else { return false }
        return abs(neck.x - root.x) * aspect < abs(neck.y - root.y)
    }

    /// 表示される向きでの縦横比（幅 ÷ 高さ）。90° 回転する向きでは縦横が入れ替わる。
    /// 撮影中は動画ファイルが無く `SwingAnalyzer.Video.aspect` を使えないので、フレームの大きさから出す。
    /// 解析 CLI とテストからも呼ぶので private にしない
    static func shownAspect(width: Int, height: Int, orientation: CGImagePropertyOrientation) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: return CGFloat(height) / CGFloat(width)
        default: return CGFloat(width) / CGFloat(height)
        }
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

    /// 頭の位置。正面なら鼻。後方視点で顔が向こうを向いて鼻が取れないときは目、それも無ければ耳で代用する
    /// （見えている方の真ん中。代用に切り替わるときの数 % のずれは軌跡の平滑化で吸収する）
    private static func headLocation(in observation: VNHumanBodyPoseObservation) -> CGPoint? {
        typealias Joint = VNHumanBodyPoseObservation.JointName
        for joints in [[Joint.nose], [.leftEye, .rightEye], [.leftEar, .rightEar]] {
            if let point = CGPoint.center(of: joints.compactMap { location(of: $0, in: observation) }) { return point }
        }
        return nil
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
}

extension PoseTrack {
    /// 範囲内のコマから部位（手・頭・左右の肩・左右の股関節）の軌跡を作る（平滑化まで）。
    /// 解析時（`SwingAnalysisResult.jointTrails`）と、後から軌跡だけを作るとき（`ClipStore.requestTrails`）で共通
    /// - range: 保存する範囲（採用スイングの周り）
    /// - swing: 採用スイング（アドレス〜フィニッシュ）。均す窓の広さを決める
    func jointTrails(in range: ClosedRange<Double>, swing: ClosedRange<Double>) -> JointTrails {
        let samples = frames.filter { range.contains($0.time) }.map {
            JointTrailSample(time: $0.time, hands: $0.wrist, head: $0.head,
                             leftShoulder: $0.leftShoulder, rightShoulder: $0.rightShoulder,
                             leftHip: $0.leftHip, rightHip: $0.rightHip)
        }
        return JointTrails(samples: samples).smoothed(swingSamples: samples.filter { swing.contains($0.time) }.count)
    }
}
