import Foundation

/// 撮影の設定（アプリ全体で 1 つ。`Library.capture` に保存し、撮影画面の「…」で変える）
struct CaptureSettings: Codable, Equatable {
    /// 使うカメラ。背面は 240fps まで、前面は 120fps まで（打席から画面が見えるのは前面だけ）
    enum Camera: String, Codable, CaseIterable {
        case back
        case front

        var label: String {
            switch self {
            case .back: return "背面"
            case .front: return "前面"
            }
        }
    }

    /// 選べるフレームレート
    static let frameRates = [240, 120]

    var camera: Camera = .back
    /// 望むフレームレート。実際に使う値は `effectiveFrameRate`（前面は 120 まで）
    var frameRate: Int = 240
    /// 合図の音（見えた / 切れている / 取れた / 止まった）を鳴らすか。マナーモードに関わらず、ここで切る
    var soundEnabled: Bool = true
    /// 録画を始めてから止めるまでの動画を全部残すか（調査用）。区切りファイルを消さず、止めたときに 1 本につないで
    /// 写真ライブラリのアルバム「SwingDuet」と `Documents/CaptureTakes/` に保存する（後者は Mac から取り出せる）。容量を食うので、検出が安定したら切る
    var keepsFullTake: Bool = true

    var effectiveFrameRate: Int {
        camera == .front ? min(frameRate, 120) : frameRate
    }

    private enum CodingKeys: String, CodingKey {
        case camera, frameRate, soundEnabled, keepsFullTake
    }

    init() {}

    /// 後から足したキーが無い保存データも読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        camera = try c.decodeIfPresent(Camera.self, forKey: .camera) ?? .back
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 240
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        keepsFullTake = try c.decodeIfPresent(Bool.self, forKey: .keepsFullTake) ?? true
    }
}
