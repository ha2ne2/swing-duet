import Foundation
import AVFoundation
import Combine
import UIKit

/// 撮影画面の中身：カメラ（`CaptureSession`）・書き込み（`SegmentWriter`）・ライブ検出（`LiveDetector`）・ショットの切り出しと保存・合図の音をつなぐ。
///
/// フレームは撮影のキュー（`FrameWorker`）で区切りファイルに書き、15fps に間引いたものを追跡のキュー（`VisionWorker`）で Vision に掛ける。
/// スイングの候補が見つかった時点（フィニッシュの 1 秒後）で合図を鳴らし、区切りファイルが閉じたらすぐパススルーで切り出して
/// アプリ内のファイルのクリップにする（仮のフェーズ付き）。本番か素振りかの判定は後から来て、本番なら写真ライブラリに移し、素振りなら消す。
/// 打席に届く合図は音（見えた / 切れている / 取れた / 止まった）。設計は docs/design/260912_2251-capture-screen.md
@MainActor
final class CaptureController: ObservableObject {

    enum Phase: Equatable {
        case preparing
        case ready
        case recording
        case stopping
        case finished
    }

    /// 画面の縁の色（近づいたときに一目で分かる）
    enum Edge: Equatable {
        case idle
        case seen
        case cutOff
        case hit
        case warning
    }

    /// 帯に出すショット（切り出し中は `clipID` が nil）
    struct ShotItem: Identifiable, Equatable {
        let id: UUID
        var clipID: UUID?
    }

    /// ライブ検出が見つけたスイングの候補（切り出す範囲付き）と、その範囲のライブ追跡から付けた仮の解析
    struct LiveShot {
        let shot: Shot
        let provisional: SwingAnalysisResult
    }

    /// 帯の 1 つのショットの仕事：区切りファイルが閉じたら切り出してアプリ内のクリップにし（`export` → `clipID`）、
    /// 判定（`verdict`）が来たら本番なら写真ライブラリに移し、素振りなら消す（`settle`）。両方済んだら列から外れる
    private struct Cut {
        let item: ShotItem
        let live: LiveShot
        var export: Task<Void, Never>?
        var clipID: UUID?
        var verdict: LiveShotJudge.Verdict?
        var settle: Task<Void, Never>?
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

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var edge: Edge = .idle
    @Published private(set) var statusText = ""
    @Published private(set) var banner: String?
    @Published private(set) var shots: [ShotItem] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var frameRate = 0
    @Published private(set) var setupError: String?
    @Published private(set) var isPermissionDenied = false
    @Published private(set) var summary: Summary?

    let store: ClipStore
    let capture = CaptureSession()

    /// 大きな球数の代わりに「＋1」を出す間（縁が白く光っている間と同じ）
    var showsPlusOne: Bool { edge == .hit }

    private let sounds = CaptureSounds()
    private let frameWorker = FrameWorker()
    private let visionQueue = DispatchQueue(label: "com.ha2ne2.SwingDuet.capture.vision", qos: .userInitiated)
    private var visionWorker: VisionWorker?
    private let directory: URL

    private var startedAt: Date?
    private var closedSegments: [SegmentWriter.Segment] = []
    /// 切り出しと判定の反映が済んでいないショット
    private var cuts: [Cut] = []
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

    /// 始めるのに要る空き容量（区切り 1 本 ＋ 切り出しの余裕）と、撮影中に止める空き容量
    static let requiredFreeSpace: Int64 = 2_000_000_000
    static let minimumFreeSpace: Int64 = 1_000_000_000
    /// 人物がこれだけ写らなければ止める（球拾い・休憩で忘れたときの電池と熱）
    static let autoStopAfter: TimeInterval = 5 * 60
    /// 1 球も切り出せなかったとき、これ以上撮れていれば長い動画として残す
    static let minimumTakeDuration = 10.0
    /// 決まったショットが来る余地（フィニッシュから待つ 6 秒 ＋ 余白）。閉じた区切りはこれを過ぎてから消す
    static let segmentRetention = 10.0
    /// 全体の動画を残す置き場（Documents/CaptureTakes。Mac から取り出せる）
    static var takesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureTakes", isDirectory: true)
    }

    init(store: ClipStore) {
        self.store = store
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Capture", isDirectory: true)
        let frameWorker = frameWorker
        capture.frameHandler = { sample in frameWorker.handle(sample) }
    }

    // MARK: - 準備

    /// カメラの権限を取り、セッションを組んでプレビューを始める
    func prepare() async {
        phase = .preparing
        try? FileManager.default.removeItem(at: directory)   // 前回の残り（途中で落ちたとき）
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard status == .authorized else {
            isPermissionDenied = true
            setupError = "カメラの使用が許可されていません。設定 → SwingDuet → カメラ で許可してください。"
            return
        }
        capture.pressureHandler = { [weak self] level in self?.systemPressureChanged(level) }
        capture.interruptionHandler = { [weak self] reason in
            guard let self, phase == .recording else { return }
            Task { await self.stop(reason: reason) }
        }
        await configure()
    }

    /// 設定（カメラ・フレームレート）どおりにセッションを組み直す。録画中は呼ばない
    func configure() async {
        guard phase != .recording, phase != .stopping else { return }
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
            frameRate = format.frameRate
            capture.queue.async { capture.startRunning() }
            attachRotation()
            setupError = nil
            phase = .ready
            statusText = "録画を押して打席へ。構えると音で知らせます"
        } catch {
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
        ticker?.cancel()
        log?.close()
        log = nil
        let capture = capture
        capture.queue.async { capture.stopRunning() }
        sounds.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        store.analysisPaused = false
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 録画

    func record() {
        guard phase == .ready, let format = capture.format else { return }
        if let free = Self.freeSpace(), free < Self.requiredFreeSpace {
            banner = "空き容量が 2 GB を切っているので始められません"
            return
        }
        // 動画の向きは始めた時点の端末の向きで固定する（背面カメラを縦に置けば 90°）。Vision にも同じ向きで渡す
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let transform = CGAffineTransform.rotation(degrees: angle)
        let rotated = Int(angle.rounded()) % 180 == 90
        let aspect = rotated ? Double(format.height) / Double(format.width) : Double(format.width) / Double(format.height)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        stamp = formatter.string(from: Date())
        let log = CaptureLog(stamp: stamp)
        self.log = log
        let orientation = PoseTracker.orientation(from: transform)
        log.line("start camera=\(store.capture.camera.rawValue) fps=\(format.frameRate) size=\(format.width)x\(format.height) angle=\(angle) orientation=\(orientation.rawValue) keepsFullTake=\(store.capture.keepsFullTake) keyFrameInterval=\(CaptureSession.keyFrameInterval)")
        let writer = SegmentWriter(directory: directory, settings: capture.recommendedVideoSettings(frameRate: format.frameRate), transform: transform)
        let vision = VisionWorker(orientation: orientation, frameRate: Double(format.frameRate), videoAspect: aspect, log: log)
        visionWorker = vision
        wire(vision)
        let frameWorker = frameWorker
        capture.queue.async { frameWorker.begin(with: writer) }

        startedAt = Date()
        lastPersonSeenAt = Date()
        closedSegments = []
        cuts = []
        shots = []
        elapsed = 0
        edge = .idle
        banner = nil
        summary = nil
        phase = .recording
        statusText = "打席で構えてください"
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

    /// 追跡のキューと撮影のキューの間の配線。撮影のキューは 15fps に間引いたフレームを追跡のキューに渡し、
    /// 追跡のキューは結果を main に戻し、区切りを閉じる合図を撮影のキューに送る
    private func wire(_ vision: VisionWorker) {
        let frameWorker = frameWorker
        let visionQueue = visionQueue
        let captureQueue = capture.queue
        frameWorker.onVision = { pixelBuffer, time in
            visionQueue.async {
                let result = vision.process(pixelBuffer, at: time)
                captureQueue.async {
                    frameWorker.visionFinished()
                    if result.closeSegment { frameWorker.requestClose() }
                }
                Task { @MainActor [weak self] in self?.apply(result) }
            }
        }
        frameWorker.onSegmentClosed = { [weak self] segment in
            Task { @MainActor in self?.segmentClosed(segment) }
        }
    }

    /// 追跡の結果を画面と音に反映する
    private func apply(_ result: VisionWorker.Result) {
        guard phase == .recording || phase == .stopping else { return }
        if result.personVisible {
            lastPersonSeenAt = Date()
        } else if edge == .seen || edge == .cutOff {
            edge = .idle
            statusText = "打席で構えてください"
        }
        switch result.stance {
        case .seen:
            edge = .seen
            statusText = "見えています"
            play(.seen)
            log?.line("stance seen")
        case .cutOff:
            edge = .cutOff
            statusText = "頭か足が切れています。三脚を直してください"
            play(.cutOff)
            log?.line("stance cutOff")
        case nil:
            break
        }
        register(result.registered)
        judge(result.verdicts)
    }

    /// 見つかった候補を帯に出し、合図を鳴らし、切り出しの列に足す（判定はまだ）
    private func register(_ liveShots: [LiveShot]) {
        for live in liveShots {
            let item = ShotItem(id: UUID(), clipID: nil)
            shots.append(item)
            cuts.append(Cut(item: item, live: live))
            play(.captured)
            flashPlusOne()
            log?.line(String(format: "registered range=[%.2f, %.2f] impact=%.2f", live.shot.range.lowerBound, live.shot.range.upperBound, live.shot.swing.phases.impact))
        }
        startCuts()
    }

    /// 判定を対応するショットに付け、切り出しが済んでいれば反映する
    private func judge(_ verdicts: [LiveShotJudge.Verdict]) {
        for verdict in verdicts {
            guard let index = cuts.firstIndex(where: { LiveShotJudge.isSameSwing($0.live.shot.swing, verdict.candidate) }) else {
                log?.line(String(format: "verdict without shot impact=%.2f", verdict.candidate.phases.impact))
                continue
            }
            cuts[index].verdict = verdict
            log?.line(String(format: "verdict %@ impact=%.2f", verdict.shot == nil ? "practice" : "shot", verdict.candidate.phases.impact))
            settleIfReady(cuts[index].item.id)
        }
    }

    /// 切り出しと判定の両方がそろったショットを片付ける：本番は写真ライブラリに移し、素振りはクリップごと消す
    private func settleIfReady(_ itemID: UUID) {
        guard let index = cuts.firstIndex(where: { $0.item.id == itemID }),
              let clipID = cuts[index].clipID, let verdict = cuts[index].verdict, cuts[index].settle == nil else { return }
        if verdict.shot != nil {
            cuts[index].settle = Task { [store] in
                await store.promoteCapturedShot(clipID)
                await MainActor.run { self.cuts.removeAll { $0.item.id == itemID } }
            }
        } else {
            store.discardCapturedShot(clipID)
            shots.removeAll { $0.id == itemID }
            cuts.removeAll { $0.item.id == itemID }
        }
    }

    private func segmentClosed(_ segment: SegmentWriter.Segment) {
        closedSegments.append(segment)
        log?.line(String(format: "segment closed start=%.2f end=%.2f dropped=%d", segment.start, segment.end, segment.droppedFrames))
        startCuts()
        pruneSegments()
    }

    /// まだ切り出していないショットのうち、インパクトを含む区切りファイルが閉じたものを切り出す
    private func startCuts() {
        for index in cuts.indices where cuts[index].export == nil {
            let cut = cuts[index]
            guard let segment = closedSegments.first(where: { $0.contains(cut.live.shot.swing.phases.impact) }) else { continue }
            cuts[index].export = Task { await self.export(cut, from: segment) }
        }
    }

    /// 区切りファイルからショットを切り出し、アプリ内のファイルの仮のクリップにする。判定が既に来ていれば続けて反映する
    private func export(_ cut: Cut, from segment: SegmentWriter.Segment) async {
        defer { pruneSegments() }
        let shot = cut.live.shot
        guard let local = segment.localRange(of: shot.range), let startedAt else {
            drop(cut.item.id)
            return
        }
        do {
            let url = try await VideoImporter.exportSegment(of: AVURLAsset(url: segment.url), range: local)
            let shotAt = startedAt.addingTimeInterval(segment.start + local.lowerBound)
            // 区切りの端で範囲が切り詰められていれば、仮の解析もその分にずらす
            let offset = segment.start + local.lowerBound - shot.range.lowerBound
            let provisional = cut.live.provisional.sliced(to: offset...(offset + local.upperBound - local.lowerBound))
            let clip = try store.keepCapturedShot(at: url, shotAt: shotAt, provisional: provisional)
            log?.line(String(format: "shot kept range=[%.2f, %.2f] clip=%@", shot.range.lowerBound, shot.range.upperBound, clip.id.uuidString))
            guard let index = cuts.firstIndex(where: { $0.item.id == cut.item.id }),
                  let shotIndex = shots.firstIndex(where: { $0.id == cut.item.id }) else {   // 帯で消された
                store.discardCapturedShot(clip.id)
                return
            }
            cuts[index].clipID = clip.id
            shots[shotIndex].clipID = clip.id
            settleIfReady(cut.item.id)
        } catch {
            print("ショットの切り出しに失敗: \(error.localizedDescription)")
            log?.line("shot failed: \(error.localizedDescription)")
            drop(cut.item.id)
            banner = "ショットを切り出せませんでした"
        }
    }

    /// 帯とショットの列から外す（切り出せなかったとき）
    private func drop(_ itemID: UUID) {
        shots.removeAll { $0.id == itemID }
        cuts.removeAll { $0.item.id == itemID }
    }

    /// 縁を白く光らせて「＋1」を出す（1.2 秒）。その間に縁が別の色になっていれば（構えの判定・熱）そちらを優先して戻さない
    private func flashPlusOne() {
        let before = edge
        edge = .hit
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, edge == .hit else { return }
            edge = before == .hit ? .seen : before
        }
    }

    /// 切り出しに使わず、決まったショットが来る余地も無くなった区切りファイルを消す。全体の動画を残す設定なら止めるまで消さない
    private func pruneSegments() {
        let now = sessionTime
        let finished = phase == .finished || phase == .stopping
        guard finished || !store.capture.keepsFullTake else { return }
        for segment in closedSegments {
            let referenced = cuts.contains { segment.contains($0.live.shot.swing.phases.impact) }
            guard !referenced, finished || segment.end + Self.segmentRetention < now else { continue }
            try? FileManager.default.removeItem(at: segment.url)
            closedSegments.removeAll { $0.id == segment.id }
        }
    }

    /// 帯のショットを消す（誤検出をその場で捨てる）。判定を待っていた分は待たない
    func delete(_ item: ShotItem) {
        if let clipID = item.clipID {
            store.delete([clipID])
        }
        drop(item.id)
    }

    // MARK: - 止める

    /// 録画を止め、残りのショットを切り出して保存する。`reason` は自動で止めたときの理由（音でも知らせる）
    func stop(reason: String? = nil) async {
        guard phase == .recording else { return }
        phase = .stopping
        statusText = "保存しています…"
        ticker?.cancel()
        let background = UIApplication.shared.beginBackgroundTask()
        defer { UIApplication.shared.endBackgroundTask(background) }

        let frameWorker = frameWorker
        let capture = capture
        let last: SegmentWriter.Segment? = await withCheckedContinuation { continuation in
            capture.queue.async { frameWorker.finish { continuation.resume(returning: $0) } }
        }
        if let last { closedSegments.append(last) }
        let time = sessionTime
        if let vision = visionWorker {
            let visionQueue = visionQueue
            let flushed: VisionWorker.Result = await withCheckedContinuation { continuation in
                visionQueue.async { continuation.resume(returning: vision.flush(at: time)) }
            }
            register(flushed.registered)
            judge(flushed.verdicts)
        }
        for cut in cuts { await cut.export?.value }
        for cut in cuts { settleIfReady(cut.item.id) }   // 切り出しより先に来ていた判定を反映する
        for cut in cuts { await cut.settle?.value }
        // 閉じたファイルにインパクトが入らなかった分（無いはず）は諦める。以後 `shots` は保存できたショットだけ
        for cut in cuts where cut.clipID == nil { shots.removeAll { $0.id == cut.item.id } }
        cuts = []

        // 全体の動画：区切りファイルを 1 本につなぐ。残す設定（調査用）なら写真ライブラリと Documents/CaptureTakes に。
        // 1 球も切り出せなかったときは、設定に関わらず長い動画（解析待ちのスイング）として足し、既存の分割に任せる（検出が外れたときの保険）。
        // つなげなければ区切りごとに同じ扱いをする
        var savedTake = false
        var keptTake = false
        let keeps = store.capture.keepsFullTake
        let ordered = closedSegments.sorted { $0.start < $1.start }
        if let startedAt, let first = ordered.first, keeps || shots.isEmpty {
            let takes: [(url: URL, start: Double, duration: Double)]
            do {
                let merged = try VideoImporter.concatenate(ordered.map(\.url))
                takes = [(merged, first.start, ordered.last.map { $0.end - first.start } ?? 0)]
                log?.line("take merged segments=\(ordered.count)")
            } catch {
                log?.line("take merge failed: \(error.localizedDescription). keeping segments separately")
                takes = ordered.map { ($0.url, $0.start, $0.end - $0.start) }
            }
            try? FileManager.default.createDirectory(at: Self.takesDirectory, withIntermediateDirectories: true)
            for (index, take) in takes.enumerated() {
                let shotAt = startedAt.addingTimeInterval(take.start)
                let asSwing = shots.isEmpty && take.duration >= Self.minimumTakeDuration
                guard keeps || asSwing else { continue }
                if keeps {
                    let kept = Self.takesDirectory.appendingPathComponent(takes.count == 1 ? "\(stamp).mov" : "\(stamp)-\(index + 1).mov")
                    let copied = (try? FileManager.default.copyItem(at: take.url, to: kept)) != nil
                    keptTake = keptTake || copied
                    log?.line("take kept=\(copied) path=\(kept.lastPathComponent)")
                }
                if let source = try? await store.persistVideo(at: take.url, shotAt: shotAt) {
                    if asSwing {
                        store.addCapturedTake(source: source, shotAt: shotAt)
                        savedTake = true
                    }
                    log?.line("take saved index=\(index + 1) asSwing=\(asSwing)")
                } else {
                    log?.line("take save failed index=\(index + 1)")
                }
            }
        }
        phase = .finished
        pruneSegments()
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
        summary = Summary(shotCount: shots.count, savedTake: savedTake, keptTake: keptTake, reason: reason)
    }

    /// アプリが背景に回った：カメラは使えなくなるので止める（書きかけのファイルを閉じる）
    func appDidEnterBackground() {
        guard phase == .recording else { return }
        Task { await stop(reason: "アプリが背景に回ったので止めました") }
    }

    /// 1 秒ごと：経過時間、電池・容量・人物の不在で止める
    private func tick() async {
        guard phase == .recording, let startedAt else { return }
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
        guard phase == .recording else { return }
        let frameWorker = frameWorker
        let capture = capture
        switch level {
        case .nominal, .fair:
            capture.queue.async { frameWorker.visionInterval = 1 / LiveDetector.sampleRate }
            banner = nil
            if reducedFrameRate {
                reducedFrameRate = false
                switchFrameRate(to: store.capture.effectiveFrameRate)
                if edge == .warning { edge = .seen }
            }
        case .serious:
            capture.queue.async { frameWorker.visionInterval = 1 / 10 }
            banner = "本体が熱くなっています。追跡を減らしました"
        case .critical:
            if !reducedFrameRate, frameRate > 120 {
                reducedFrameRate = true
                switchFrameRate(to: 120)
            }
            banner = "本体が熱いので 120fps に落としました。冷えれば 240fps に戻ります"
            edge = .warning
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
        let frameWorker = frameWorker
        let vision = visionWorker
        let visionQueue = visionQueue
        capture.queue.async {
            capture.setFrameRate(frameRate)
            frameWorker.requestClose()
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

    private static func freeSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - 撮影のキューの仕事

/// 撮影のキュー（`CaptureSession.queue`）だけが触る状態：区切りファイルへの書き込みと、追跡へ渡すフレームの間引き
private final class FrameWorker {
    private var writer: SegmentWriter?
    private var startPTS: Double?
    private var nextVisionAt = 0.0
    private var visionBusy = false
    private var closeRequested = false
    /// 追跡に渡す間隔（秒）。熱で下げる
    var visionInterval = 1 / LiveDetector.sampleRate
    /// 追跡へ渡す（受け手は自分のキューで処理し、終わったら `visionFinished` を撮影のキューで呼ぶ）
    var onVision: ((CVPixelBuffer, Double) -> Void)?
    /// 区切りファイルが閉じた（任意のスレッド）
    var onSegmentClosed: ((SegmentWriter.Segment) -> Void)?

    func begin(with writer: SegmentWriter) {
        self.writer = writer
        startPTS = nil
        nextVisionAt = 0
        visionBusy = false
        closeRequested = false
    }

    func handle(_ sample: CMSampleBuffer) {
        guard let writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let start = startPTS ?? pts
        startPTS = start
        let time = pts - start
        if closeRequested {
            closeRequested = false
            let closed = onSegmentClosed
            writer.rotate { segment in segment.map { closed?($0) } }
        }
        do {
            try writer.append(sample, at: time)
        } catch {
            print("区切りファイルを始められません: \(error)")
        }
        if time >= nextVisionAt, !visionBusy, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
            nextVisionAt = time + visionInterval
            visionBusy = true
            onVision?(pixelBuffer, time)
        }
    }

    func visionFinished() {
        visionBusy = false
    }

    func requestClose() {
        closeRequested = true
    }

    /// 最後の区切りを閉じて書き込みを終える
    func finish(completion: @escaping (SegmentWriter.Segment?) -> Void) {
        guard let writer else {
            completion(nil)
            return
        }
        self.writer = nil
        writer.rotate(completion: completion)
    }
}

// MARK: - 追跡のキューの仕事

/// 追跡のキューだけが触る状態：Vision の追跡（`FrameTracker`）、ライブ検出（`LiveDetector`）、区切りの計画（`SegmentPlanner`）
private final class VisionWorker {
    struct Result {
        var stance: LiveDetector.StanceEvent? = nil
        /// 新しく見つかった候補（切り出して仮に保存する）
        var registered: [CaptureController.LiveShot] = []
        /// 本番か素振りかの判定
        var verdicts: [LiveShotJudge.Verdict] = []
        var closeSegment = false
        var personVisible = false
    }

    private var tracker = PoseTracker.FrameTracker()
    private var detector = LiveDetector()
    private var planner = SegmentPlanner()
    private let orientation: CGImagePropertyOrientation
    /// 撮影のフレームレート（仮の解析のクリップに書く。熱で変わる）
    var frameRate: Double
    private let videoAspect: Double
    private let log: CaptureLog?
    private var nextLogAt = 0.0

    init(orientation: CGImagePropertyOrientation, frameRate: Double, videoAspect: Double, log: CaptureLog?) {
        self.orientation = orientation
        self.frameRate = frameRate
        self.videoAspect = videoAspect
        self.log = log
    }

    func process(_ pixelBuffer: CVPixelBuffer, at time: Double) -> Result {
        let person = tracker.person(in: pixelBuffer, orientation: orientation)
        let frame = tracker.frame(at: time, person: person)
        let update = detector.add(frame)
        let quiet = detector.isQuiet(at: time)
        var close = false
        if planner.shouldClose(at: time, lastFinish: detector.lastFinish, quiet: quiet) {
            planner.didClose(at: time)
            close = true
            log?.line(String(format: "close segment t=%.2f lastFinish=%@ quiet=%d", time, detector.lastFinish.map { String(format: "%.2f", $0) } ?? "-", quiet ? 1 : 0))
        }
        for candidate in update.observed {
            let p = candidate.phases
            log?.line(String(format: "candidate A=%.2f T=%.2f I=%.2f F=%.2f rise=%.2f peak=%.2f estimated=%d pending=%d",
                             p.address, p.top, p.impact, p.finish, candidate.rise, candidate.peakSpeed, candidate.estimated.count, detector.judge.pending.count))
        }
        if time >= nextLogAt {
            nextLogAt = time + 1
            let hand = detector.currentHandHeight().map { String(format: "%.2f", $0) } ?? "-"
            let bounds = frame.bodyBounds.map { String(format: "[%.2f %.2f %.2f %.2f]", $0.minX, $0.minY, $0.maxX, $0.maxY) } ?? "-"
            log?.line(String(format: "t=%.2f person=%d wrist=%.0f%% hand=%@ bounds=%@ quiet=%d motion=%d pending=%d",
                             time, frame.bodyBounds == nil ? 0 : 1, detector.recentWristCoverage(at: time) * 100, hand, bounds,
                             quiet ? 1 : 0, detector.inMotion(at: time) ? 1 : 0, detector.judge.pending.count))
        }
        return Result(stance: update.stance, registered: update.registered.map(liveShot), verdicts: update.verdicts,
                      closeSegment: close, personVisible: detector.isPersonVisible(at: time))
    }

    /// 止めるとき：待たずに全部決める
    func flush(at time: Double) -> Result {
        let flushed = detector.flush(at: time)
        log?.line(String(format: "flush t=%.2f registered=%d verdicts=%d frames=%d", time, flushed.registered.count, flushed.verdicts.count, detector.frames.count))
        return Result(registered: flushed.registered.map(liveShot), verdicts: flushed.verdicts)
    }

    /// 候補に、切り出す範囲と、その範囲のライブ追跡を 1 本の動画として見た仮の解析（切り出したクリップにすぐ付けるフェーズ）を添える
    private func liveShot(_ candidate: SwingCandidate) -> CaptureController.LiveShot {
        let range = LiveDetector.range(of: candidate)
        let track = detector.track(in: range)
        let duration = range.upperBound - range.lowerBound
        let provisional = SwingAnalysisResult(duration: duration, frameRate: frameRate, videoAspect: videoAspect, pose: track,
                                              candidates: SwingDetector.detect(track: track, duration: duration))
        return CaptureController.LiveShot(shot: Shot(range: range, swing: candidate), provisional: provisional)
    }
}
