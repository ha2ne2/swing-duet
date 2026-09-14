import Foundation
import AVFoundation
import CoreGraphics

/// 動画 1 本の自動解析の入口：人物追跡（PoseTracker）→ スイング検出（SwingDetector）。
/// 結果は `SwingAnalysisResult.videoConfig(fileName:)` でクリップに保存する形に変換する
enum SwingAnalyzer {

    static func analyze(url: URL) async throws -> SwingAnalysisResult {
        try await analyze(asset: AVURLAsset(url: url))
    }

    /// 動画は `AVAsset` で受ける（アプリ内のファイルも写真ライブラリの原本も同じ）
    static func analyze(asset: AVAsset) async throws -> SwingAnalysisResult {
        let video = try await loadVideo(asset: asset)
        return SwingAnalysisResult(pose: try track(video), duration: video.duration,
                                   frameRate: video.frameRate, videoAspect: video.aspect)
    }

    /// 人物追跡だけを行う。解析済みのクリップに軌跡だけを後から作るとき（`ClipStore.requestTrails`）に使う
    static func trackPose(asset: AVAsset) async throws -> PoseTrack {
        try track(try await loadVideo(asset: asset))
    }

    private static func track(_ video: Video) throws -> PoseTrack {
        try PoseTracker.track(
            asset: video.asset, videoTrack: video.track, frameRate: video.frameRate, orientation: video.orientation)
    }

    /// 解析に使う動画の情報（`loadVideo` で読む）
    struct Video {
        var asset: AVAsset
        var track: AVAssetTrack
        var duration: Double
        var frameRate: Double
        /// 表示される映像の縦横比（幅 ÷ 高さ。回転メタデータ適用後）
        var aspect: Double
        var orientation: CGImagePropertyOrientation
    }

    /// 解析に必要な動画の情報をまとめて読む。解析 CLI（scripts/analyze-swing）の関節ダンプからも使うので private にしない
    static func loadVideo(url: URL) async throws -> Video {
        try await loadVideo(asset: AVURLAsset(url: url))
    }

    static func loadVideo(asset: AVAsset) async throws -> Video {
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.noVideoTrack
        }
        let (nominalFrameRate, naturalSize, transform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
        let shownSize = naturalSize.applying(transform)   // 回転メタデータ適用後の大きさ（符号は向きなので絶対値で使う）
        let aspect = shownSize.height != 0 ? abs(shownSize.width / shownSize.height) : 0
        // NOTE: 壊れた動画では長さが NaN になる（`CMTime` が invalid）。そのまま保存に回すと JSON に書けず、
        //       以後この端末の保存がすべて失敗し続ける。読めない動画として弾き、「解析できませんでした」に落とす
        guard duration.isFinite, duration > 0, Double(nominalFrameRate).isFinite, aspect.isFinite else {
            throw VideoError.unreadable
        }
        return Video(
            asset: asset, track: track, duration: duration, frameRate: Double(nominalFrameRate),
            aspect: aspect, orientation: PoseTracker.orientation(from: transform))
    }
}
