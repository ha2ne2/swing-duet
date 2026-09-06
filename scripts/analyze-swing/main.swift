// スイング検出を macOS 上で実行する開発用 CLI（実機なしで検出ロジックを確認する。Vision は Mac でも動く）。
//
// ビルド:  swiftc -O -o build/analyze-swing SwingDuet/Services/{SwingAnalyzer,PoseTracker,SwingDetector}.swift \
//              SwingDuet/Models/{SwingModels,Geometry}.swift scripts/analyze-swing/main.swift
// 使い方:  build/analyze-swing [--series] <動画>...
//          --series を付けると手首の位置と速度の系列も出す（# の長さは速度）
import Foundation

func describe(_ p: PhaseSet) -> String {
    String(format: "A=%.2f T=%.2f I=%.2f F=%.2f (テンポ %@)", p.address, p.top, p.impact, p.finish, p.tempoText)
}

/// 人が読む形式で 1 本分の結果を出す
func printReport(_ result: SwingAnalysisResult, name: String, elapsed: TimeInterval, showSeries: Bool) {
    print(String(format: "# %@  duration=%.2fs fps=%.1f 検出率=%.0f%%  (%.1fs)",
                 name, result.duration, result.frameRate, result.pose.coverage * 100, elapsed))
    if let focus = result.focusRect {
        print(String(format: "  人物範囲: x=%.2f..%.2f y=%.2f..%.2f（縦横比 %.2f）",
                     focus.minX, focus.maxX, focus.minY, focus.maxY, result.videoAspect))
    }
    let chosen = result.chosen
    if let chosen {
        if chosen.downswingUnobserved {
            print("  注意: 採用スイングの切り返し〜インパクトがブレで未観測（信頼度低）")
        }
    } else {
        print("  検出失敗 → フォールバック: \(describe(result.phases))")
    }
    for (i, c) in result.candidates.enumerated() {
        let mark = c.phases == chosen?.phases ? "★" : " "
        print(String(format: "  %@ 候補%d: %@  score=%.2f peak=%.2f back=%.2f follow=%.2f gap=%.2fs",
                     mark, i + 1, describe(c.phases), c.score, c.peakSpeed, c.backswingSpan, c.followSpan, c.downswingGap))
    }
    if showSeries { printSeries(result) }
}

/// 手首の位置と速度の系列。速度は手首を検出できた（前のフレームからつながる）サンプルだけにある
func printSeries(_ result: SwingAnalysisResult) {
    let samples = SwingDetector.speedSeries(track: result.pose)
    let maxSpeed = samples.map(\.speed).max() ?? 1
    var si = 0
    for (t, p) in zip(result.pose.times, result.pose.points) {
        var speedText = ""
        if si < samples.count, abs(samples[si].time - t) < 1e-6 {
            speedText = String(format: "%.3f %@", samples[si].speed,
                               String(repeating: "#", count: Int(samples[si].speed / maxSpeed * 40)))
            si += 1
        }
        let pointText = p.map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? "  -  "
        print(String(format: "  %5.2f %9@ %@", t, pointText, speedText))
    }
}

let args = CommandLine.arguments.dropFirst()
let showSeries = args.contains("--series")
let paths = args.filter { !$0.hasPrefix("--") }
guard !paths.isEmpty else {
    print("usage: analyze-swing [--series] <video>...")
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
        } catch {
            print("\(url.lastPathComponent): ERROR \(error)")
        }
    }
    done.signal()
}
done.wait()
