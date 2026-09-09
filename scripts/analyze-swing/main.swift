// スイング検出を macOS 上で実行する開発用 CLI（実機なしで検出ロジックを確認する。Vision は Mac でも動く）。
//
// ビルド:  swiftc -O -o build/analyze-swing SwingDuet/Services/{SwingAnalyzer,PoseTracker,SwingDetector}.swift \
//              SwingDuet/Models/{SwingModels,Geometry}.swift scripts/analyze-swing/main.swift
// 使い方:  build/analyze-swing [--series] [--joints] <動画>...
//          --series  手の高さ（腰 = 0、首 = 1）と速度（体の大きさ/秒）の系列も出す（# の長さは速度）
//          --joints  左右の手首・腰・首の生の位置と信頼度を出す（手首が隠れる区間を調べるとき）
import Foundation
import AVFoundation
import Vision

func describe(_ p: PhaseSet) -> String {
    String(format: "A=%.2f T=%.2f I=%.2f F=%.2f (テンポ %@)", p.address, p.top, p.impact, p.finish, p.tempoText)
}

/// 人が読む形式で 1 本分の結果を出す
func printReport(_ result: SwingAnalysisResult, name: String, elapsed: TimeInterval, showSeries: Bool) {
    print(String(format: "# %@  duration=%.2fs fps=%.1f 検出率=%.0f%% 体の大きさ=%@  (%.1fs)",
                 name, result.duration, result.frameRate, result.pose.coverage * 100,
                 result.pose.torsoHeight.map { String(format: "%.3f", $0) } ?? "-", elapsed))
    if let focus = result.focusRect {
        print(String(format: "  人物範囲: x=%.2f..%.2f y=%.2f..%.2f（縦横比 %.2f）",
                     focus.minX, focus.maxX, focus.minY, focus.maxY, result.videoAspect))
    }
    let chosen = result.chosen
    if chosen == nil {
        print("  検出失敗 → フォールバック: \(describe(result.phases))")
    }
    for (i, c) in result.candidates.enumerated() {
        let mark = c.phases == chosen?.phases ? "★" : " "
        let estimated = c.estimated.isEmpty ? "" : "  推定=" + SwingPhase.allCases.filter { c.estimated.contains($0) }.map(\.shortLabel).joined()
        print(String(format: "  %@ 候補%d: %@  score=%.2f rise=%.2f peak=%.2f%@",
                     mark, i + 1, describe(c.phases), c.score, c.rise, c.peakSpeed, estimated))
    }
    if result.lowConfidence { print("  信頼度低（手動確認を促す）") }
    if showSeries { printSeries(result) }
}

/// 手の高さと速度の系列。手首を検出できたフレームだけにある。腰・首が取れていないフレームは r / n を空白にする
func printSeries(_ result: SwingAnalysisResult) {
    let samples = SwingDetector.handSamples(track: result.pose)
    let maxSpeed = samples.compactMap(\.speed).max() ?? 1
    var si = 0
    print("   t     手首(x,y)  r n   高さ   速度")
    for (i, t) in result.pose.times.enumerated() {
        let point = result.pose.points[i].map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? "  -  "
        let joints = (result.pose.roots[i] == nil ? " " : "r") + " " + (result.pose.necks[i] == nil ? " " : "n")
        var series = ""
        if si < samples.count, abs(samples[si].time - t) < 1e-6 {
            let s = samples[si]
            series = String(format: "%6.2f  %@ %@", s.height,
                            s.speed.map { String(format: "%5.2f", $0) } ?? "    -",
                            String(repeating: "#", count: Int((s.speed ?? 0) / maxSpeed * 40)))
            si += 1
        }
        print(String(format: "  %5.2f %9@  %@ %@", t, point, joints, series))
    }
}

/// 左右の手首・腰・首を信頼度付きで出す（手首が体に隠れる区間の調査用）
func printJoints(url: URL) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SwingAnalyzerError.noVideoTrack }
    let (fps, transform) = try await track.load(.nominalFrameRate, .preferredTransform)
    let frames = try PoseTracker.jointDump(
        asset: asset, videoTrack: track, frameRate: Double(fps), orientation: PoseTracker.orientation(from: transform))
    func text(_ point: VNRecognizedPoint?) -> String {
        point.map { String(format: "%.2f,%.2f c%.2f", $0.location.x, $0.location.y, $0.confidence) } ?? "      -        "
    }
    print("   t     左手首             右手首             腰                 首")
    for frame in frames {
        print(String(format: "  %5.2f  %@  %@  %@  %@", frame.time,
                     text(frame.joints[.leftWrist]), text(frame.joints[.rightWrist]), text(frame.joints[.root]), text(frame.joints[.neck])))
    }
}

let args = CommandLine.arguments.dropFirst()
let showSeries = args.contains("--series")
let showJoints = args.contains("--joints")
let paths = args.filter { !$0.hasPrefix("--") }
guard !paths.isEmpty else {
    print("usage: analyze-swing [--series] [--joints] <video>...")
    exit(1)
}

let done = DispatchSemaphore(value: 0)
Task {
    for path in paths {
        let url = URL(fileURLWithPath: path)
        do {
            let started = Date()
            let result = try await SwingAnalyzer.analyze(url: url)
            printReport(result, name: url.lastPathComponent, elapsed: Date().timeIntervalSince(started), showSeries: showSeries)
            if showJoints { try await printJoints(url: url) }
        } catch {
            print("\(url.lastPathComponent): ERROR \(error)")
        }
    }
    done.signal()
}
done.wait()
