// E2E 用の合成スイング動画を生成する（棒人間がアドレス → バックスイング → ダウンスイング → フォロー → フィニッシュと動く）。
// 人物検出はされないので、フロー確認・再生同期の確認用。
//
// ビルド:   swiftc -O -o build/gen-swing-video .claude/skills/e2e-simulator/gen-swing-video.swift
// 使い方:   build/gen-swing-video <出力.mov> <fps> <秒数> <トップ位置 0-1> <インパクト位置 0-1>
// 例:       build/gen-swing-video build/self_240fps.mov 240 3.0 0.50 0.62
import AVFoundation
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 6, let fps = Int32(args[2]), let duration = Double(args[3]),
      let topT = Double(args[4]), let impactT = Double(args[5]) else {
    FileHandle.standardError.write("usage: gen-swing-video <out.mov> <fps> <seconds> <top 0-1> <impact 0-1>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]
let addressEnd = 0.15               // ここまで静止（アドレス）
let finishStart = impactT + 0.18    // ここから静止（フィニッシュ）
let width = 720, height = 1280

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * min(max(t, 0), 1) }
func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

/// 腕とクラブの角度（度）。0 = 真下（アドレス）、負 = バックスイング側、正 = フォロー側
func angle(at t: Double) -> Double {
    if t < addressEnd { return 0 }
    if t < topT { return lerp(0, -160, ease((t - addressEnd) / (topT - addressEnd))) }
    if t < impactT { return lerp(-160, 10, ease((t - topT) / (impactT - topT))) }
    if t < finishStart { return lerp(10, 170, ease((t - impactT) / (finishStart - impactT))) }
    return 170
}

let total = Int(Double(fps) * duration)
for i in 0..<total {
    while !input.isReadyForMoreMediaData { usleep(500) }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    // 背景（芝と空）
    ctx.setFillColor(CGColor(red: 0.55, green: 0.75, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: 500))
    ctx.setFillColor(CGColor(red: 0.6, green: 0.8, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 500, width: width, height: height - 500))

    let t = Double(i) / Double(total)
    let rad = angle(at: t) * .pi / 180
    let shoulder = CGPoint(x: 360, y: 760)
    ctx.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)); ctx.setLineWidth(14); ctx.setLineCap(.round)
    ctx.setFillColor(CGColor(red: 0.9, green: 0.75, blue: 0.6, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: shoulder.x - 45, y: shoulder.y + 40, width: 90, height: 90))              // 頭
    ctx.move(to: shoulder); ctx.addLine(to: CGPoint(x: shoulder.x, y: shoulder.y - 260)); ctx.strokePath()  // 胴
    ctx.move(to: CGPoint(x: shoulder.x, y: shoulder.y - 260)); ctx.addLine(to: CGPoint(x: shoulder.x - 70, y: shoulder.y - 520)); ctx.strokePath()
    ctx.move(to: CGPoint(x: shoulder.x, y: shoulder.y - 260)); ctx.addLine(to: CGPoint(x: shoulder.x + 70, y: shoulder.y - 520)); ctx.strokePath()
    let hands = CGPoint(x: shoulder.x + 200 * sin(rad), y: shoulder.y - 200 * cos(rad))
    ctx.move(to: shoulder); ctx.addLine(to: hands); ctx.strokePath()                                          // 腕
    let clubHead = CGPoint(x: hands.x + 300 * sin(rad), y: hands.y - 300 * cos(rad))
    ctx.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 1)); ctx.setLineWidth(8)
    ctx.move(to: hands); ctx.addLine(to: clubHead); ctx.strokePath()                                          // クラブ
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("wrote \(outPath) fps=\(fps) frames=\(total) status=\(writer.status.rawValue) error=\(writer.error.map { "\($0)" } ?? "none")")
