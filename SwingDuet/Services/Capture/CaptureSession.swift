import Foundation
import AVFoundation
import VideoToolbox

/// `AVCaptureSession` の設定と実行。背面（または前面）の広角カメラを 1920×1080・240fps（前面は 120fps）のフォーマットにし、
/// フレームを `queue` で `frameHandler` に渡す（録画中は `SegmentWriter` と 15fps の追跡へ）。
/// 熱（`systemPressureState`）と中断（電話・背景）は main で `pressureHandler` / `interruptionHandler` に知らせる。
/// 設計は docs/design/260912_1951-in-app-slowmo-capture-and-shot-split.md §4.1 と docs/design/260912_2251-capture-screen.md §5.1
final class CaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum Error: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "カメラを使えません。"
            case .cannotAddInput, .cannotAddOutput: return "カメラを設定できませんでした。"
            }
        }
    }

    /// 実際に選ばれたフォーマット
    struct Format: Equatable {
        var frameRate: Int
        var width: Int
        var height: Int
    }

    /// キーフレーム間隔（フレーム）。240fps で毎秒 8 枚。15 は毎秒 16 枚で容量が膨らみ、60 は戻る操作が重い（実測で決める）
    static let keyFrameInterval = 30

    let session = AVCaptureSession()
    /// フレームを受け取るキュー（書き込みもここで行う）
    let queue = DispatchQueue(label: "com.ha2ne2.SwingDuet.capture.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private(set) var device: AVCaptureDevice?
    private(set) var format: Format?

    /// フレームごとに `queue` で呼ばれる
    var frameHandler: ((CMSampleBuffer) -> Void)?
    /// 熱などのシステム圧の変化（main）
    var pressureHandler: ((AVCaptureDevice.SystemPressureState.Level) -> Void)?
    /// 中断（電話・背景・別アプリ）と実行時エラー（main）
    var interruptionHandler: ((String) -> Void)?

    private var pressureObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        // 音声は撮らないので、音のセッションはこちら（合図の音）で持つ
        session.automaticallyConfiguresApplicationAudioSession = false
        // DTS の助言：activeFormat を自分で選ぶときは広色域の自動設定を切る
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.interruptionHandler?(Self.describe(reason))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.interruptionHandler?("カメラでエラーが起きました（\(error?.localizedDescription ?? "不明")）")
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 設定

    /// カメラとフレームレートを決めてセッションを組む（`queue` で呼ぶ。実行中なら止めてから）。選ばれたフォーマットを返す
    func configure(camera: CaptureSettings.Camera, frameRate: Int) throws -> Format {
        let position: AVCaptureDevice.Position = camera == .front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw Error.noCamera
        }
        guard let chosen = Self.bestFormat(of: device, frameRate: frameRate) else { throw Error.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Error.cannotAddInput }
        session.addInput(input)
        // フォーマットは入力を足した後に、プリセットを inputPriority にしてから設定する（プリセットのままだと入力を足すときに上書きされる）
        session.sessionPreset = .inputPriority
        try device.lockForConfiguration()
        device.activeFormat = chosen.format
        let duration = CMTime(value: 1, timescale: CMTimeScale(chosen.frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()

        // 420v：エンコーダが受け取る形そのもの（BGRA は 2.6 倍のメモリ。TN3121）。遅れたフレームは捨てない（書き込みに使う）
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Error.cannotAddOutput }
        session.addOutput(output)
        // 手ぶれ補正は切る（高フレームレートでは対応しない上、映像の端を削る）。データ出力の接続には回転を設定しない（配信が途切れる。WWDC23）
        if let connection = output.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        self.device = device
        let dimensions = CMVideoFormatDescriptionGetDimensions(chosen.format.formatDescription)
        let format = Format(frameRate: chosen.frameRate, width: Int(dimensions.width), height: Int(dimensions.height))
        self.format = format

        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            let level = device.systemPressureState.level
            DispatchQueue.main.async { self?.pressureHandler?(level) }
        }
        return format
    }

    /// 実行中にフレームレートだけ変える（熱で 120 に落とす・戻す）。同じフォーマットのまま間隔だけ変える
    func setFrameRate(_ frameRate: Int) {
        guard let device, var format else { return }
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(frameRate) }
        guard supported, (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        format.frameRate = frameRate
        self.format = format
    }

    /// 1920×1080 で望むフレームレートを出せるフォーマット。無ければ 120 → 60 → 30 と落とし、それも無ければ最初の 1080p
    static func bestFormat(of device: AVCaptureDevice, frameRate: Int) -> (format: AVCaptureDevice.Format, frameRate: Int)? {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == 1920 && dimensions.height == 1080
                && CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        for fps in [frameRate, 120, 60, 30] where fps <= frameRate {
            if let format = candidates.first(where: { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) } }) {
                return (format, fps)
            }
        }
        guard let any = candidates.first else { return nil }
        return (any, Int(any.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
    }

    /// `AVAssetWriterInput` の映像の設定：カメラアプリと同じ推奨設定（HEVC）に、高フレームレートに要る指定を重ねる。
    /// 30fps 超では `AVVideoExpectedSourceFrameRateKey` が無いとエンコーダがコマを落とす。B フレーム無しとキーフレーム間隔は
    /// 戻る操作の絵の更新のため（TODO.md I）。間隔は 15 / 30 / 60 を実機で測って決める（design/260912_2251 §5.1）
    func recommendedVideoSettings(frameRate: Int) -> [String: Any] {
        var settings = output.recommendedVideoSettings(forVideoCodecType: .hevc, assetWriterOutputFileType: .mov) ?? [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: format?.width ?? 1920,
            AVVideoHeightKey: format?.height ?? 1080,
        ]
        var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        compression[AVVideoExpectedSourceFrameRateKey] = frameRate
        compression[AVVideoMaxKeyFrameIntervalKey] = Self.keyFrameInterval
        compression[AVVideoAllowFrameReorderingKey] = false
        compression[kVTCompressionPropertyKey_RealTime as String] = true
        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
    }

    // MARK: - 実行

    func startRunning() {
        guard !session.isRunning else { return }
        session.startRunning()
    }

    func stopRunning() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    // MARK: - フレーム

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameHandler?(sampleBuffer)
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "アプリが背景に回ったので止めました"
        case .audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient: return "電話などでカメラが使えなくなったので止めました"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "他のアプリと並んでいるとカメラを使えないので止めました"
        case .videoDeviceNotAvailableDueToSystemPressure: return "本体が熱くなったので止めました"
        default: return "カメラが使えなくなったので止めました"
        }
    }
}
