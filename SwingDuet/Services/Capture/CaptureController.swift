import Foundation
import AVFoundation
import Combine
import UIKit

/// カメラの準備・録画・停止を管理し、フレーム書き込み、姿勢追跡、ショット保存をつなぐ。
/// UI はメインアクター、書き込みは capture.queue、姿勢追跡は visionQueue が所有する。
/// 停止はすべての書き込みと切り出しを待ってから後片付けする。
@MainActor
final class CaptureController: ObservableObject {

    /// 撮影画面の進み方。NOTE: スイングの 4 フェーズ（`SwingPhase`）とは別物なので `Phase` と呼ばない
    enum RecordingState: Equatable {
        case preparing
        case ready
        case recording
        case stopping
        case finished
    }

    /// 画面の縁の色（近づいたときに一目で分かる）。3 つの事実（構え・熱・＋1 の点滅）から決まる
    enum Edge: Equatable {
        case idle
        case seen
        case cutOff
        case hit
        case warning
    }

    /// 打席の人物の写り方
    enum Stance: Equatable {
        /// まだ構えていない（人物が見えていない・構えの判定が出ていない）
        case unseen
        case seen
        /// 頭か足が枠の外
        case cutOff
    }

    /// 止めた結果（ホームの帯に出す）
    struct Summary: Equatable {
        var shotCount: Int
        /// 1 球も切り出せず、撮った動画を長い動画（解析待ちのスイング）として残した
        var savedTake: Bool
        /// 全体の動画を写真ライブラリと `Documents/CaptureTakes/` に残した（調査用の設定）
        var keptTake: Bool
        /// 自動で止めた理由（自分で止めたときは nil）
        var reason: String?
    }

    @Published private(set) var state: RecordingState = .preparing
    @Published private(set) var stance: Stance = .unseen
    /// 熱で追跡かフレームレートを落としている
    @Published private(set) var isOverheated = false
    /// 1 球取れた合図（1.2 秒だけ）
    @Published private(set) var showsPlusOne = false
    @Published private(set) var banner: String?
    /// 帯に出すショット（`pipeline` が持つ列の写し。画面へ配るためだけに `@Published` にする）
    @Published private(set) var shots: [ShotPipeline.Item] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var frameRate = 0
    @Published private(set) var setupError: String?
    @Published private(set) var isPermissionDenied = false
    @Published private(set) var summary: Summary?

    let store: ClipStore
    let capture = CaptureSession()

    /// 画面の縁の色。＋1 の点滅 → 熱 → 構え の順に強い
    var edge: Edge {
        if showsPlusOne { return .hit }
        if isOverheated { return .warning }
        switch stance {
        case .unseen: return .idle
        case .seen: return .seen
        case .cutOff: return .cutOff
        }
    }

    /// 画面に出す一言。状態から決まるので、場面ごとに書き換えない
    var statusText: String {
        switch state {
        case .preparing: return ""
        case .ready: return "録画を押して打席へ。構えると音で知らせます"
        case .recording:
            switch stance {
            case .unseen: return "打席で構えてください"
            case .seen: return "見えています"
            case .cutOff: return "頭か足が切れています。三脚を直してください"
            }
        case .stopping, .finished: return "保存しています…"
        }
    }

    private let sounds = CaptureSounds()
    private let frameWriter = CaptureFrameWriter()
    private let visionQueue = DispatchQueue(label: "com.ha2ne2.SwingDuet.capture.vision", qos: .userInitiated)
    private var poseProcessor: CapturePoseProcessor?
    private let directory: URL

    private var startedAt: Date?
    /// 閉じた区切りファイル
    private var segments = SegmentStore()
    /// 1 球ずつの切り出しと判定の反映（録画 1 回ぶん）
    private var pipeline: ShotPipeline?
    private var lastPersonSeenAt = Date()
    private var ticker: Task<Void, Never>?
    private var reducedFrameRate = false
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// 調査用のログ（録画中だけ）
    private var log: CaptureLog?
    /// 録画を始めた日時の印（ログと全体の動画のファイル名）
    private var stamp = ""
    /// 背景で止めている最中に持ち時間が切れた（全体の動画をつながずに切り上げる）
    private var isBackgroundTimeUp = false
    private var isTornDown = false
    private var configurationID = UUID()
    /// 保存できなかった全体の動画は、再起動や次の撮影でも作業領域ごと残す
    private var preservesWorkingFiles = false

    /// 始めるのに要る空き容量（区切り 1 本 ＋ 切り出しの余裕）と、撮影中に止める空き容量
    static let requiredFreeSpace: Int64 = 2_000_000_000
    static let minimumFreeSpace: Int64 = 1_000_000_000
    /// 人物がこれだけ写らなければ止める（球拾い・休憩で忘れたときの電池と熱）
    static let autoStopAfter: TimeInterval = 5 * 60
    /// 1 球も切り出せなかったとき、これ以上撮れていれば長い動画として残す
    static let minimumTakeDuration = 10.0
    /// 全体の動画を残す置き場（Documents/CaptureTakes。Mac から取り出せる）
    static var takesDirectory: URL {
        URL.documents.appendingPathComponent("CaptureTakes", isDirectory: true)
    }

    init(store: ClipStore) {
        self.store = store
        directory = Self.takesDirectory.appendingPathComponent("Pending-\(UUID().uuidString)", isDirectory: true)
        let frameWriter = frameWriter
        capture.frameHandler = { sample in frameWriter.handle(sample) }
    }

    // MARK: - 準備

    /// カメラの権限を取り、セッションを組んでプレビューを始める
    func prepare() async {
        guard !isTornDown else { return }
        state = .preparing
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            setupError = "動画の保存先を作れません。空き容量を確認してください。"
            return
        }
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard !isTornDown, !Task.isCancelled else { return }
        guard status == .authorized else {
            isPermissionDenied = true
            setupError = "カメラの使用が許可されていません。設定 → SwingDuet → カメラ で許可してください。"
            return
        }
        capture.pressureHandler = { [weak self] level in self?.systemPressureChanged(level) }
        capture.interruptionHandler = { [weak self] reason in
            guard let self, state == .recording else { return }
            Task { await self.stop(reason: reason) }
        }
        await configure()
    }

    /// 設定（カメラ・フレームレート）どおりにセッションを組み直す。録画中は呼ばない
    func configure() async {
        guard !isTornDown, state != .recording, state != .stopping, state != .finished else { return }
        state = .preparing
        let requestID = UUID()
        configurationID = requestID
        let settings = store.capture
        let capture = capture
        do {
            let format: CaptureSession.Format = try await withCheckedThrowingContinuation { continuation in
                capture.queue.async {
                    do {
                        capture.stopRunning()
                        continuation.resume(returning: try capture.configure(camera: settings.camera, frameRate: settings.effectiveFrameRate))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            guard !isTornDown, !Task.isCancelled, configurationID == requestID else { return }
            frameRate = format.frameRate
            capture.queue.async { capture.startRunning() }
            attachRotation()
            setupError = nil
            state = .ready
        } catch {
            guard !isTornDown, configurationID == requestID else { return }
            #if targetEnvironment(simulator)
            setupError = "シミュレータでは撮影できません。実機で使ってください。"
            #else
            setupError = error.localizedDescription
            #endif
        }
    }

    /// プレビューの層（`CameraPreviewView` が作る）。端末の向きに合わせて回す
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        attachRotation()
    }

    private func attachRotation() {
        guard let previewLayer, let device = capture.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        let apply: (CGFloat) -> Void = { angle in
            guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
        apply(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { apply(angle) }
        }
    }

    /// 撮影画面を閉じるとき
    func teardown() {
        isTornDown = true
        configurationID = UUID()
        // 画面の破棄が録画・保存に重なっても、入力ファイルは停止処理が使い切るまで残す
        if state == .recording {
            Task { await stop() }
            return
        }
        guard state != .stopping else { return }
        ticker?.cancel()
        log?.close()
        log = nil
        let capture = capture
        capture.queue.async { capture.stopRunning() }
        sounds.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        store.analysisPaused = false
        if !preservesWorkingFiles { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - 録画

    func record() {
        guard state == .ready, let format = capture.format else { return }
        if let free = Self.freeSpace(), free < Self.requiredFreeSpace {
            banner = "空き容量が 2 GB を切っているので始められません"
            return
        }
        // 動画の向きは始めた時点の端末の向きで固定する（背面カメラを縦に置けば 90°）。Vision にも同じ向きで渡す
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let transform = CGAffineTransform.rotation(degrees: angle)
        let orientation = PoseTracker.orientation(from: transform)
        let aspect = Double(PoseTracker.shownAspect(width: format.width, height: format.height, orientation: orientation))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        stamp = formatter.string(from: Date())
        let log = CaptureLog(stamp: stamp)
        self.log = log
        log.line("start camera=\(store.capture.camera.rawValue) fps=\(format.frameRate) size=\(format.width)x\(format.height) angle=\(angle) orientation=\(orientation.rawValue) keepsFullTake=\(store.capture.keepsFullTake) keyFrameInterval=\(CaptureSession.keyFrameInterval)")
        let writer = SegmentWriter(directory: directory, settings: capture.recommendedVideoSettings(frameRate: format.frameRate),
                                   transform: transform, log: log)
        let vision = CapturePoseProcessor(orientation: orientation, frameRate: Double(format.frameRate), videoAspect: aspect, log: log)
        poseProcessor = vision
        wire(vision)
        // 受け口は撮影のキューが動き出す前に繋ぐ（`begin` の後だと、キューが読む最中に main から書くことになる）
        frameWriter.onWriteFailed = { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                await self.stop(reason: "動画を書き込めなくなったので止めました")
            }
        }
        let frameWriter = frameWriter
        capture.queue.async {
            frameWriter.log = log
            frameWriter.begin(with: writer)
        }

        let startedAt = Date()
        self.startedAt = startedAt
        lastPersonSeenAt = startedAt
        segments = SegmentStore()
        pipeline = makePipeline(startedAt: startedAt, log: log)
        isBackgroundTimeUp = false
        shots = []
        elapsed = 0
        stance = .unseen
        isOverheated = false
        showsPlusOne = false
        banner = nil
        summary = nil
        state = .recording
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        store.analysisPaused = true
        sounds.activate()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
    }

    /// 録画 1 回ぶんの切り出しの列。帯（`shots`）はここが持つ列の写しで、更新はこの 1 か所だけ
    private func makePipeline(startedAt: Date, log: CaptureLog) -> ShotPipeline {
        let pipeline = ShotPipeline(store: store, exporter: SegmentExporter(), startedAt: startedAt, log: log)
        pipeline.onItemsChanged = { [weak self] items in self?.shots = items }
        pipeline.onCutFailed = { [weak self] in self?.banner = "ショットを切り出せませんでした" }
        return pipeline
    }

    /// 追跡のキューと撮影のキューの間の配線。撮影のキューは 15fps に間引いたフレームを追跡のキューに渡し、
    /// 追跡のキューは結果を main に戻し、区切りを閉じる合図を撮影のキューに送る
    private func wire(_ vision: CapturePoseProcessor) {
        let frameWriter = frameWriter
        let visionQueue = visionQueue
        let captureQueue = capture.queue
        frameWriter.onVision = { pixelBuffer, time in
            visionQueue.async {
                let result = vision.process(pixelBuffer, at: time)
                captureQueue.async {
                    frameWriter.visionFinished()
                    if result.closeSegment { frameWriter.requestClose() }
                }
                DispatchQueue.main.async { [weak self] in self?.apply(result) }
            }
        }
        frameWriter.onSegmentClosed = { [weak self] segment in
            self?.segmentClosed(segment)
        }
    }

    /// 追跡の結果を画面と音に反映する
    private func apply(_ result: CapturePoseProcessor.Result) {
        guard state == .recording || state == .stopping else { return }
        if result.personVisible {
            lastPersonSeenAt = Date()
        } else if stance != .unseen {
            stance = .unseen
        }
        switch result.stance {
        case .seen:
            stance = .seen
            play(.seen)
            log?.line("stance seen")
        case .cutOff:
            stance = .cutOff
            play(.cutOff)
            log?.line("stance cutOff")
        case nil:
            break
        }
        for live in result.registered {
            pipeline?.register(live)
            play(.captured)
            flashPlusOne()
        }
        pipeline?.startCuts(from: segments)
        pipeline?.apply(result.verdicts)
    }

    private func segmentClosed(_ segment: SegmentWriter.Segment) {
        segments.append(segment)
        log?.line(String(format: "segment closed start=%.2f end=%.2f dropped=%d", segment.start, segment.end, segment.droppedFrames))
        pipeline?.startCuts(from: segments)
        pruneSegments()
    }

    /// 「＋1」を 1.2 秒出す（その間は縁も白く光る）
    private func flashPlusOne() {
        showsPlusOne = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.showsPlusOne = false
        }
    }

    /// 要らなくなった区切りファイルを消す。
    /// NOTE: 録画中だけ。止めている間は全体の動画をつなぐのに要るので、消すのは片付けが済んでから（`stop`）
    private func pruneSegments() {
        guard state == .recording else { return }
        segments.prune(now: sessionTime,
                       waitingFor: pipeline?.impactsWaitingForCut ?? [],
                       keepsAll: store.capture.keepsFullTake)
    }

    /// 帯のショットを消す（誤検出をその場で捨てる）。判定を待っていた分は待たない
    func delete(_ item: ShotPipeline.Item) {
        pipeline?.remove(item.id)
    }

    // MARK: - 止める

    /// 録画を止め、残りのショットを切り出して保存する。`reason` は自動で止めたときの理由（音でも知らせる）
    func stop(reason: String? = nil) async {
        guard state == .recording else { return }
        state = .stopping
        ticker?.cancel()
        // NOTE: 背景に回ってから止めるときのために、満了ハンドラで「つなぐのをやめる」に切り替える。
        //       持ち時間（〜30 秒）を超えると、ハンドラが無ければアプリごと落とされて後始末が途中で切れる
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.isBackgroundTimeUp = true
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        defer {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }

        let frameWriter = frameWriter
        let capture = capture
        await withCheckedContinuation { continuation in
            capture.queue.async { frameWriter.finish { continuation.resume() } }
        }
        await finishCuts()
        let take = await saveTake()
        state = .finished
        if !preservesWorkingFiles { segments.removeAll() }
        capture.queue.async { capture.stopRunning() }
        UIApplication.shared.isIdleTimerDisabled = false
        store.analysisPaused = false
        if reason != nil {
            play(.stopped)
            banner = reason
        }
        log?.line("stop shots=\(shots.count) reason=\(reason ?? "user")")
        log?.close()
        log = nil
        let summaryReason = preservesWorkingFiles
            ? [reason, "保存できなかった動画をアプリ内に残しました"].compactMap { $0 }.joined(separator: "。")
            : reason
        summary = Summary(shotCount: shots.count, savedTake: take.savedAsSwing, keptTake: take.kept, reason: summaryReason)
        if isTornDown { teardown() }
    }

    /// 残っているショットを最後まで片付ける：追跡に残った候補を出し切り、切り出しと判定の反映を待つ
    private func finishCuts() async {
        let time = sessionTime
        if let vision = poseProcessor {
            let visionQueue = visionQueue
            let flushed: CapturePoseProcessor.Result = await withCheckedContinuation { continuation in
                visionQueue.async {
                    let result = vision.flush(at: time)
                    // 先行する検出結果と同じ main キューへ並べ、反映し終えてから残りを処理する
                    DispatchQueue.main.async { continuation.resume(returning: result) }
                }
            }
            for live in flushed.registered { pipeline?.register(live) }
            pipeline?.startCuts(from: segments)
            pipeline?.apply(flushed.verdicts)
        }
        await pipeline?.finish()
    }

    /// 録画を始めてから止めるまでの動画（区切りファイルを 1 本につないだもの）の後始末。
    /// 残す設定（調査用）なら写真ライブラリと `Documents/CaptureTakes/` に置き、1 球も切り出せなかったときは
    /// 設定に関わらず長い動画（解析待ちのスイング）として足して既存の分割に任せる（検出が外れたときの保険）。
    /// つなげなかったときは区切りごとに同じ扱いをする
    private func saveTake() async -> (savedAsSwing: Bool, kept: Bool) {
        let keeps = store.capture.keepsFullTake
        let ordered = segments.ordered
        guard let startedAt, let first = ordered.first, keeps || shots.isEmpty else { return (false, false) }

        // 1 本につなぐと同じ大きさの複製ができる。空きが足りないときと背景の持ち時間が切れたときは、区切りのまま残す
        let needed = ordered.reduce(Int64(0)) { $0 + (Self.fileSize(of: $1.url) ?? 0) }
        let canMerge = !isBackgroundTimeUp && (Self.freeSpace() ?? 0) > needed + Self.minimumFreeSpace
        let takes: [(url: URL, start: Double, duration: Double)]
        do {
            guard canMerge else { throw VideoError.unreadable }
            let urls = ordered.map(\.url)
            let output = directory.appendingPathComponent("take.mov")
            let merged = try await Task.detached(priority: .utility) {
                try VideoImporter.concatenate(urls, output: output)
            }.value
            takes = [(merged, first.start, ordered.last.map { $0.end - first.start } ?? 0)]
            log?.line("take merged segments=\(ordered.count)")
        } catch {
            log?.line("take merge skipped or failed (canMerge=\(canMerge)): keeping \(ordered.count) segments separately")
            takes = ordered.map { ($0.url, $0.start, $0.end - $0.start) }
        }
        try? FileManager.default.createDirectory(at: Self.takesDirectory, withIntermediateDirectories: true)

        var savedAsSwing = false
        var kept = false
        for (index, take) in takes.enumerated() {
            let shotAt = startedAt.addingTimeInterval(take.start)
            let asSwing = shots.isEmpty && take.duration >= Self.minimumTakeDuration
            guard keeps || asSwing else { continue }
            if keeps {
                let path = Self.takesDirectory.appendingPathComponent(takes.count == 1 ? "\(stamp).mov" : "\(stamp)-\(index + 1).mov")
                let copied = (try? FileManager.default.copyItem(at: take.url, to: path)) != nil
                kept = kept || copied
                log?.line("take kept=\(copied) path=\(path.lastPathComponent)")
                // 退避できないまま原本を移すと、一覧に登録しない全体動画の参照が失われる
                if !copied {
                    preservesWorkingFiles = true
                    continue
                }
            }
            if let source = try? await store.persistVideo(at: take.url, shotAt: shotAt) {
                if asSwing {
                    store.addCapturedTake(source: source, shotAt: shotAt)
                    savedAsSwing = true
                }
                log?.line("take saved index=\(index + 1) asSwing=\(asSwing)")
            } else {
                preservesWorkingFiles = true
                log?.line("take save failed index=\(index + 1): keeping working files")
            }
        }
        return (savedAsSwing, kept)
    }

    /// アプリが背景に回った：カメラは使えなくなるので止める（書きかけのファイルを閉じる）
    func appDidEnterBackground() {
        guard state == .recording else { return }
        Task { await stop(reason: "アプリが背景に回ったので止めました") }
    }

    /// 1 秒ごと：経過時間、電池・容量・人物の不在で止める
    private func tick() async {
        guard state == .recording, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if UIDevice.current.batteryState != .charging, UIDevice.current.batteryLevel >= 0, UIDevice.current.batteryLevel < 0.1 {
            await stop(reason: "電池が 10% を切ったので止めました")
        } else if let free = Self.freeSpace(), free < Self.minimumFreeSpace {
            await stop(reason: "空き容量が少ないので止めました")
        } else if Date().timeIntervalSince(lastPersonSeenAt) >= Self.autoStopAfter {
            await stop(reason: "5 分間だれも写らなかったので止めました")
        }
    }

    /// 熱（システム圧）：serious で追跡を 10fps に、critical で 120fps に落として縁を橙、shutdown は止める。戻れば元に
    private func systemPressureChanged(_ level: AVCaptureDevice.SystemPressureState.Level) {
        guard state == .recording else { return }
        let frameWriter = frameWriter
        let capture = capture
        switch level {
        case .nominal, .fair:
            capture.queue.async { frameWriter.visionInterval = 1 / LiveDetector.sampleRate }
            banner = nil
            isOverheated = false
            if reducedFrameRate {
                reducedFrameRate = false
                switchFrameRate(to: store.capture.effectiveFrameRate)
            }
        case .serious:
            capture.queue.async { frameWriter.visionInterval = 1 / 10 }
            banner = "本体が熱くなっています。追跡を減らしました"
        case .critical:
            if !reducedFrameRate, frameRate > 120 {
                reducedFrameRate = true
                switchFrameRate(to: 120)
            }
            banner = "本体が熱いので 120fps に落としました。冷えれば 240fps に戻ります"
            isOverheated = true
        case .shutdown:
            Task { await stop(reason: "本体が熱くなったので止めました") }
        default:
            break
        }
        log?.line("pressure \(level.rawValue)")
    }

    /// 録画中にフレームレートを変える。区切りを閉じて、以後のファイルとショットは新しいレートになる
    private func switchFrameRate(to frameRate: Int) {
        let capture = capture
        let frameWriter = frameWriter
        let vision = poseProcessor
        let visionQueue = visionQueue
        capture.queue.async {
            capture.setFrameRate(frameRate)
            frameWriter.requestClose()
        }
        visionQueue.async { vision?.frameRate = Double(frameRate) }
        self.frameRate = frameRate
    }

    // MARK: - 補助

    private var sessionTime: Double {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func play(_ cue: CaptureSounds.Cue) {
        sounds.isEnabled = store.capture.soundEnabled
        sounds.play(cue)
    }

    /// ファイルの大きさ（取れなければ nil）
    private static func fileSize(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) }
    }

    private static func freeSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
