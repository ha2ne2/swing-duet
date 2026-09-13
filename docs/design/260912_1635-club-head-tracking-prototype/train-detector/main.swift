// クラブヘッド検出器を Create ML（転移学習）で学習し、Core ML モデルに書き出す（Mac だけで動く開発用コマンド）
//
//   swiftc -O -o build/train-detector docs/design/260912_1635-club-head-tracking-prototype/train-detector/main.swift
//   build/train-detector <train ディレクトリ> <valid ディレクトリ> <出力 .mlmodel> [--iterations 2000] [--batch N] [--session build/train-session] [--resume]
//
// 各ディレクトリは画像と Create ML 形式の `_annotations.createml.json`（Roboflow の書き出し）を含む。
// アノテーションは中心 x, y と幅・高さのピクセル値・左上原点（Create ML の既定と同じ）。
// 学習はジョブ（`MLObjectDetector.train`）として動かし、段階（特徴の取り出し / 学習）・進んだ枚数と反復・損失・途中保存に加えて、
// その段階の速さから「残り時間」と「完了時刻」を標準出力に出す。
// 同期版（`MLObjectDetector(trainingData:)`）は進捗も途中保存も無く、19,000 枚で一晩走ったまま Mac の再起動で消えたので使わない。
// 反復回数は必ず指定する。省略時の自動値は `5000 × √(枠の数) ÷ 32` で、このデータ（枠 27,127 個）では約 26,000 反復（6〜9 時間）になる。
// 転移学習は 1,000〜2,000 反復で損失が下げ止まるので 2,000 を上限にする。
// 途中で落ちたら `--resume` で同じ --session から続きを再開する（特徴の取り出し結果も途中保存に含まれる）。
// 数時間走るので、Mac の自動スリープを止めてログに流す：
//   caffeinate -is build/train-detector ... --iterations 2000 > build/train-detector.log 2>&1 &
import Combine
import CreateML
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: train-detector <train dir> <valid dir> <out.mlmodel> [--iterations N] [--batch N] [--session dir] [--resume]")
    exit(1)
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func source(_ dir: String) -> MLObjectDetector.DataSource {
    let url = URL(fileURLWithPath: dir)
    return .directoryWithImages(at: url, annotationFile: url.appendingPathComponent("_annotations.createml.json"))
}

// ログファイルに流したときも 1 行ずつ即座に書く（既定はブロック単位のバッファで、tail -f で何も見えない）
setvbuf(stdout, nil, _IOLBF, 0)

let iterations = option("--iterations").flatMap(Int.init) ?? 2000
let sessionDirectory = URL(fileURLWithPath: option("--session") ?? "build/train-session")
let sessionParameters = MLTrainingSessionParameters(sessionDirectory: sessionDirectory, reportInterval: 10, checkpointInterval: 100, iterations: iterations)
let parameters = MLObjectDetector.ModelParameters(
    validation: .dataSource(source(args[2])),
    batchSize: option("--batch").flatMap(Int.init),
    maxIterations: iterations,
    algorithm: .transferLearning(.objectPrint(revision: 1)))

let started = Date()
let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()
func elapsed() -> String { String(format: "%5.1f 分", Date().timeIntervalSince(started) / 60) }
func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
print("[\(clock(started))] 開始")

let job: MLJob<MLObjectDetector>
if args.contains("--resume") {
    let session = try MLObjectDetector.restoreTrainingSession(sessionParameters: sessionParameters)
    print("再開: \(sessionDirectory.path) 反復 \(session.iteration) から（\(session.phase)）")
    job = try MLObjectDetector.resume(session)
} else {
    print("学習開始: train=\(args[1]) valid=\(args[2]) iterations=\(iterations) batch=\(parameters.batchSize.map(String.init) ?? "auto") session=\(sessionDirectory.path)")
    job = try MLObjectDetector.train(trainingData: source(args[1]), annotationType: .boundingBox(), parameters: parameters, sessionParameters: sessionParameters)
}

var subscriptions = Set<AnyCancellable>()
var lastPrinted = -1
// 残り時間の見積もり：段階が変わる（または枚数が巻き戻る）たびに起点を取り直し、起点からの速さで残りを出す。
// 特徴の取り出し中は学習段階の速さがまだ分からないので、1 反復 1.2 秒（M4・16 GB・32 枚で実測、2026-09-12）と仮定して完了時刻に足す
let assumedSecondsPerIteration = 1.2
var phaseStart = Date()
var phaseStartCount = 0
var currentPhase: MLPhase?
func estimate(_ p: MLProgress, now: Date) -> String {
    if p.phase != currentPhase || p.itemCount < phaseStartCount {
        currentPhase = p.phase
        phaseStart = now
        phaseStartCount = p.itemCount
    }
    let done = p.itemCount - phaseStartCount
    let seconds = now.timeIntervalSince(phaseStart)
    guard let total = p.totalItemCount, done > 0, seconds > 5 else { return "" }
    let remainingInPhase = Double(total - p.itemCount) * seconds / Double(done)
    let remainingTotal = remainingInPhase + (p.phase == .extractingFeatures ? Double(iterations) * assumedSecondsPerIteration : 0)
    return String(format: " | この段階の残り %.0f 分、完了 %@ ごろ", remainingInPhase / 60, clock(now.addingTimeInterval(remainingTotal)))
}
// 進捗は Foundation.Progress で来る。MLProgress に変換すると段階・枚数・損失が読める。取り出し中は 200 枚ごと、学習中は報告のたびに出す
let observation = job.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
    guard let p = MLProgress(progress: progress) else { return }
    let step = p.phase == .extractingFeatures ? 200 : 1
    guard p.itemCount / step != lastPrinted / step else { return }
    lastPrinted = p.itemCount
    let now = Date()
    let metrics = p.metrics.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
    print("[\(clock(now)) \(elapsed())] \(p.phase) \(p.itemCount)/\(p.totalItemCount.map(String.init) ?? "?") \(metrics)\(estimate(p, now: now))")
}
job.phase.sink { print("[\(clock(Date())) \(elapsed())] 段階: \($0)") }.store(in: &subscriptions)
job.checkpoints.sink { print("[\(clock(Date())) \(elapsed())] 途中保存: \($0)") }.store(in: &subscriptions)

let done = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
job.result.sink(receiveCompletion: { completion in
    if case .failure(let error) = completion { print("失敗: \(error)"); exitCode = 1 }
    done.signal()
}, receiveValue: { detector in
    print("[\(clock(Date())) \(elapsed())] 学習終了")
    print("training:", detector.trainingMetrics)
    print("validation:", detector.validationMetrics)
    let metadata = MLModelMetadata(
        author: "SwingDuet",
        shortDescription: "ゴルフクラブ（club）とクラブヘッド（club_head）の検出器。Roboflow Universe「Golf club」(CC BY 4.0) で学習",
        license: "Model: MIT. Training data: CC BY 4.0 (Roboflow Universe golf-club-8jior/golf-club-urzzy)",
        version: "0.1")
    do {
        try detector.write(to: URL(fileURLWithPath: args[3]), metadata: metadata)
        print("書き出し:", args[3])
    } catch { print("書き出し失敗: \(error)"); exitCode = 1 }
}).store(in: &subscriptions)
done.wait()
_ = observation
exit(exitCode)
