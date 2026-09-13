import Foundation
import AVFoundation

/// 打席に届く合図の音（背面カメラでは画面がレンズの裏側で打席から見えないので、合図は音だけ）。
/// 見えた（♪）/ 切れている（♪♪）/ 取れた（♪ 上がる 2 音）/ 止まった（♪ー 低く長い）の 4 つを、短い電子音として合成して鳴らす。
/// 撮影を自分で始めた場面なのでタイマーと同じ扱いで、マナーモードでも鳴らす（`.playback`）。切るのは撮影画面の「…」（`isEnabled`）。
/// 他のアプリの音楽は止めない（`.mixWithOthers`）。設計は docs/design/260912_2251-capture-screen.md §1・§8
@MainActor
final class CaptureSounds {
    enum Cue: CaseIterable {
        case seen
        case cutOff
        case captured
        case stopped
    }

    var isEnabled = true
    private var players: [Cue: AVAudioPlayer] = [:]

    init() {
        for cue in Cue.allCases {
            // NOTE: 合成した WAV が読めないことは無いが、万一読めなくても音が鳴らないだけなので握りつぶす
            guard let player = try? AVAudioPlayer(data: Self.wave(for: cue)) else { continue }
            player.prepareToPlay()
            players[cue] = player
        }
    }

    /// 撮影画面にいる間だけ音のセッションを持つ
    func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func play(_ cue: Cue) {
        guard isEnabled, let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: - 音の合成

    /// 各合図の音の並び（周波数 Hz と長さ秒。周波数 0 は無音）
    private static func tones(for cue: Cue) -> [(frequency: Double, duration: Double)] {
        switch cue {
        case .seen: return [(880, 0.14)]
        case .cutOff: return [(440, 0.12), (0, 0.08), (440, 0.12)]
        case .captured: return [(660, 0.10), (990, 0.16)]
        case .stopped: return [(330, 0.55)]
        }
    }

    /// 44.1kHz・モノラル・16bit の WAV。音の頭と尻に 4ms のフェードを付けてクリックを防ぐ
    private static func wave(for cue: Cue) -> Data {
        let sampleRate = 44_100.0
        var samples: [Int16] = []
        for tone in tones(for: cue) {
            let count = Int(sampleRate * tone.duration)
            let ramp = Int(sampleRate * 0.004)
            for i in 0..<count {
                guard tone.frequency > 0 else { samples.append(0); continue }
                let envelope = min(1, Double(min(i, count - 1 - i)) / Double(ramp))
                let value = sin(2 * .pi * tone.frequency * Double(i) / sampleRate) * envelope * 0.6
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for sample in samples { append(sample) }
        return data
    }
}
