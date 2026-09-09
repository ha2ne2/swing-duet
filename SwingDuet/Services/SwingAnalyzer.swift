import Foundation
import AVFoundation
import CoreGraphics

/// 自動検出の結果（動画 1 本分）
struct SwingAnalysisResult {
    var duration: Double
    var frameRate: Double
    /// 表示される映像の縦横比（幅 ÷ 高さ。回転メタデータ適用後）
    var videoAspect: Double
    /// 人物の追跡結果
    var pose: PoseTrack
    /// 動画内で見つかったスイング候補（時系列順・採点済み。素振りを含む）。検出失敗時は空
    var candidates: [SwingCandidate]

    /// 採用するスイング（最も「振り切っている」候補）。検出失敗時は nil
    var chosen: SwingCandidate? { candidates.max { $0.score < $1.score } }

    /// 採用したスイングのフェーズ。検出失敗時はフォールバック値
    var phases: PhaseSet { chosen?.phases ?? .fallback(duration: duration) }

    /// 手動確認を促すべきか：検出失敗、手首の検出率 40% 未満、採用スイングのトップかインパクトを推定で置いたとき
    var lowConfidence: Bool {
        guard let chosen else { return true }
        return pose.coverage < 0.4 || !chosen.estimated.isEmpty
    }

    /// 採用したスイングの間（スイングが無ければ動画全体）に人物が写っていた範囲（正規化座標・左下原点）。
    /// 人物を検出できていなければ nil
    var focusRect: CGRect? {
        let swing = chosen.map { $0.phases.address...$0.phases.finish }
        let rects = pose.frames.compactMap { frame in
            (swing?.contains(frame.time) ?? true) ? frame.bodyBounds : nil
        }
        return CGRect(enclosing: rects.flatMap { [CGPoint(x: $0.minX, y: $0.minY), CGPoint(x: $0.maxX, y: $0.maxY)] })
    }

    /// 取り込んだ動画の設定を作る（拡大率と位置は自動フィットどおりの初期値）
    func videoConfig(fileName: String) -> VideoConfig {
        VideoConfig(
            fileName: fileName,
            duration: duration,
            frameRate: frameRate,
            videoAspect: videoAspect,
            focusRect: focusRect,
            phases: phases,
            lowConfidence: lowConfidence,
            candidates: candidates.map(\.phases))
    }
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

/// 動画 1 本の自動解析の入口：人物追跡（PoseTracker）→ スイング検出（SwingDetector）。
/// 結果は `SwingAnalysisResult.videoConfig(fileName:)` でプロジェクトに保存する形に変換する
enum SwingAnalyzer {

    static func analyze(url: URL) async throws -> SwingAnalysisResult {
        let video = try await loadVideo(url: url)
        let pose = try PoseTracker.track(
            asset: video.asset, videoTrack: video.track, frameRate: video.frameRate, orientation: video.orientation)
        return SwingAnalysisResult(
            duration: video.duration,
            frameRate: video.frameRate > 1 ? video.frameRate : 30,
            videoAspect: video.aspect,
            pose: pose,
            candidates: SwingDetector.detect(track: pose, duration: video.duration))
    }

    /// 調査用（`analyze-swing --joints`）：追跡対象の人物の主要関節を信頼度付きでそのまま返す
    static func jointDump(url: URL) async throws -> [JointFrame] {
        let video = try await loadVideo(url: url)
        return try PoseTracker.jointDump(
            asset: video.asset, videoTrack: video.track, frameRate: video.frameRate, orientation: video.orientation)
    }

    private struct Video {
        var asset: AVURLAsset
        var track: AVAssetTrack
        var duration: Double
        var frameRate: Double
        /// 表示される映像の縦横比（幅 ÷ 高さ。回転メタデータ適用後）
        var aspect: Double
        var orientation: CGImagePropertyOrientation
    }

    /// 解析に必要な動画の情報をまとめて読む
    private static func loadVideo(url: URL) async throws -> Video {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SwingAnalyzerError.noVideoTrack
        }
        let (nominalFrameRate, naturalSize, transform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
        let shownSize = naturalSize.applying(transform)   // 回転メタデータ適用後の大きさ（符号は向きなので絶対値で使う）
        return Video(
            asset: asset, track: track, duration: duration, frameRate: Double(nominalFrameRate),
            aspect: shownSize.height != 0 ? abs(shownSize.width / shownSize.height) : 0,
            orientation: PoseTracker.orientation(from: transform))
    }
}
