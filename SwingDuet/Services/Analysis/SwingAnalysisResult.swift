import Foundation
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

    /// 部位（手・頭・左右の肩・左右の股関節）の軌跡。採用スイングの周り（`JointTrails.sampleRange`）だけを平滑化して持つ。検出に失敗していれば無し
    var jointTrails: JointTrails? {
        guard let chosen else { return nil }
        return pose.jointTrails(in: JointTrails.sampleRange(chosen: chosen.phases, candidates: candidates.map(\.phases)),
                                swing: chosen.phases.address...chosen.phases.finish)
    }

    /// `range` の部分だけを 1 本の動画として見た解析結果（時刻は range の先頭を 0 にずらす）。
    /// 長い動画を 1 球ずつに切り出すとき、切り出した動画を解析し直さずに結果を作る。スイングは切り出した範囲の系列で検出し直す
    /// （範囲の外の素振りの尻尾が候補に混ざらないように）
    func sliced(to range: ClosedRange<Double>) -> SwingAnalysisResult {
        let slicedPose = pose.sliced(to: range)
        return SwingAnalysisResult(pose: slicedPose, duration: range.upperBound - range.lowerBound,
                                   frameRate: frameRate, videoAspect: videoAspect)
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
            candidates: candidates.map(\.phases),
            jointTrails: jointTrails)
    }
}
extension SwingAnalysisResult {
    /// 追跡結果からスイング候補を検出して組み立てる。取り込んだ動画の解析・1 球ずつの切り出し・撮影中の仮の解析で共通
    /// （候補は追跡結果と長さから決まるので、3 か所で同じ呼び出しを書かない）
    init(pose: PoseTrack, duration: Double, frameRate: Double, videoAspect: Double) {
        self.init(duration: duration, frameRate: frameRate, videoAspect: videoAspect, pose: pose,
                  candidates: SwingDetector.detect(track: pose, duration: duration))
    }
}
