// 動画の一部を再エンコードせずに切り出す（開発機だけ）:  cutclip <入力> <開始秒> <終了秒> <出力.mov>
// キーフレームの位置で切れるので、指定より少し長くなることがある
import AVFoundation
import Foundation
let a = CommandLine.arguments
guard a.count == 5, let start = Double(a[2]), let end = Double(a[3]) else { print("usage: cutclip <in> <start> <end> <out.mov>"); exit(1) }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { print("no export session"); exit(1) }
session.outputURL = URL(fileURLWithPath: a[4])
session.outputFileType = .mov
session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
let done = DispatchSemaphore(value: 0)
session.exportAsynchronously { done.signal() }
done.wait()
if session.status == .completed { print("wrote \(a[4])") } else { print("failed: \(session.error.map { "\($0)" } ?? "\(session.status.rawValue)")"); exit(1) }
