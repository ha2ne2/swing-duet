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

    /// 手動確認を促すべきか：検出失敗、手首の検出率 40% 未満、採用スイングの切り返し〜インパクトが未観測のとき
    var lowConfidence: Bool {
        guard let chosen else { return true }
        return pose.coverage < 0.4 || chosen.downswingUnobserved
    }

    /// 採用したスイングの間（スイングが無ければ動画全体）に人物が写っていた範囲（正規化座標・左下原点）。
    /// 人物を検出できていなければ nil
    var focusRect: CGRect? {
        let swing = chosen.map { $0.phases.address...$0.phases.finish }
        let rects = zip(pose.times, pose.bodyBounds).compactMap { time, rect in
            (swing?.contains(time) ?? true) ? rect : nil
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
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SwingAnalyzerError.noVideoTrack
        }
        let (nominalFrameRate, naturalSize, transform) = try await videoTrack.load(.nominalFrameRate, .naturalSize, .preferredTransform)
        let fps = Double(nominalFrameRate)
        let shownSize = naturalSize.applying(transform)   // 回転メタデータ適用後の大きさ（符号は向きなので絶対値で使う）

        let pose = try PoseTracker.track(
            asset: asset, videoTrack: videoTrack, frameRate: fps, orientation: PoseTracker.orientation(from: transform))
        return SwingAnalysisResult(
            duration: duration,
            frameRate: fps > 1 ? fps : 30,
            videoAspect: shownSize.height != 0 ? abs(shownSize.width / shownSize.height) : 0,
            pose: pose,
            candidates: SwingDetector.detect(track: pose, duration: duration))
    }
}
