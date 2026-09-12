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

    /// 動画に写る 1 球ずつのショット（切り出す範囲と採用するスイング。素振りは含めない）。1 本のスイング動画なら 1 つ、検出失敗時は空
    var shots: [Shot] { ShotSplitter.shots(candidates: candidates, duration: duration) }

    /// `range` の部分だけを 1 本の動画として見た解析結果（時刻は range の先頭を 0 にずらす）。
    /// 長い動画を 1 球ずつに切り出すとき、切り出した動画を解析し直さずに結果を作る。スイングは切り出した範囲の系列で検出し直す
    /// （範囲の外の素振りの尻尾が候補に混ざらないように）
    func sliced(to range: ClosedRange<Double>) -> SwingAnalysisResult {
        let frames = pose.frames.filter { range.contains($0.time) }.map { frame in
            var shifted = frame
            shifted.time -= range.lowerBound
            return shifted
        }
        let slicedPose = PoseTrack(frames: frames)
        let slicedDuration = range.upperBound - range.lowerBound
        return SwingAnalysisResult(
            duration: slicedDuration, frameRate: frameRate, videoAspect: videoAspect, pose: slicedPose,
            candidates: SwingDetector.detect(track: slicedPose, duration: slicedDuration))
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

/// 動画を読めないときのエラー（解析・取り込み・写真ライブラリの参照で共通）
enum VideoError: LocalizedError {
    case noVideoTrack
    case unreadable
    /// 写真ライブラリの参照が引けない（写真アプリで消された・アクセスが許可されていない）
    case missingInLibrary
    /// 写真ライブラリにはあるが原本を取れない（iCloud からダウンロードできないなど）
    case unavailable
    /// 長い動画を 1 球ずつに分けて取り込み済み（もう一度選んだ）
    case alreadySplit

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "動画トラックが見つかりませんでした。"
        case .unreadable: return "動画を読み込めませんでした。別の動画を選択してください。"
        case .missingInLibrary: return "写真ライブラリに動画がありません。写真アプリで削除されたか、アクセスが許可されていません。"
        case .unavailable: return "動画を読み込めませんでした。iCloud からダウンロードできない可能性があります。"
        case .alreadySplit: return "この動画は 1 球ずつに分けて取り込み済みです。一覧にそのスイングがあります。"
        }
    }
}

/// 動画 1 本の自動解析の入口：人物追跡（PoseTracker）→ スイング検出（SwingDetector）。
/// 結果は `SwingAnalysisResult.videoConfig(fileName:)` でクリップに保存する形に変換する
enum SwingAnalyzer {

    static func analyze(url: URL) async throws -> SwingAnalysisResult {
        try await analyze(asset: AVURLAsset(url: url))
    }

    /// 動画は `AVAsset` で受ける（アプリ内のファイルも写真ライブラリの原本も同じ）
    static func analyze(asset: AVAsset) async throws -> SwingAnalysisResult {
        let video = try await loadVideo(asset: asset)
        let pose = try PoseTracker.track(
            asset: video.asset, videoTrack: video.track, frameRate: video.frameRate, orientation: video.orientation)
        return SwingAnalysisResult(
            duration: video.duration,
            frameRate: video.frameRate,
            videoAspect: video.aspect,
            pose: pose,
            candidates: SwingDetector.detect(track: pose, duration: video.duration))
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
        return Video(
            asset: asset, track: track, duration: duration, frameRate: Double(nominalFrameRate),
            aspect: shownSize.height != 0 ? abs(shownSize.width / shownSize.height) : 0,
            orientation: PoseTracker.orientation(from: transform))
    }
}
