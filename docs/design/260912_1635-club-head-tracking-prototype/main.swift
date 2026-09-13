// クラブヘッド追跡の試作 CLI（設計 docs/design/260912_1635-club-head-tracking.md §3.1 の検証用。アプリのコードは変えない）。
//
// 方式：Vision の手首（両手首の中点）を起点に、シャフトを「手首を通る・動いている・細い線」として探し、線の先端をヘッドとする。
//   1. スイング区間の中央値画像と画素ごとのノイズで「動いている」画素のマスクを作る（ネット・地平線・的など動かない線を除く）
//   2. 手首 → 肘 → 肩の帯をマスクから外す（腕を拾わない。方向で除くと後方視点のダウンスイングで正しい線まで消える）
//   3. ヘッセ行列のリッジ（細い線の強さと向き）を局所ノイズで正規化する
//   4. 線を延長すると手首の近くを通る画素を、線の向きごとに集計し、手首側から途切れずに続く最も長く強い線を選ぶ（前フレームとの連続性で割引）
//   5. 黒い塊（ドライバーのヘッド）を連結成分で取り、前フレームの位置と速度からの予測に最も近いものを追う（位置の本命）
//   6. 外れ値を捨て、短い欠けを補間する。極座標の多項式モデル（Gehrig ら 2003）も実装してあるが、候補の質が足りず未完成（白で描く）
//
// ビルド:  swiftc -O -o build/clubtrack SwingDuet/Services/{SwingAnalyzer,PoseTracker,SwingDetector}.swift \
//              SwingDuet/Models/*.swift docs/design/260912_1635-club-head-tracking-prototype/main.swift
// 使い方:  build/clubtrack <動画> <出力先> [--min 0.5] [--rate 30] [--debug <秒>] [--model <.mlmodel|.mlmodelc>]
//          出力：heads.csv（フレームごとの手首・ヘッド。座標は正規化・左上原点）、フェーズ 8 コマの重ね描き PNG と一覧 sheet.png、
//                trajectory.png / trajectory_smoothed.png（後処理の前後）
//          --min    線らしさの閾値（局所ノイズで正規化した値）
//          --rate   解析レート（fps。姿勢は 30fps のまま）
//          --debug  その時刻のグレー・マスク・リッジ・候補の画像を書き出す
//          --model  Create ML で学習したクラブヘッド検出器（train-detector/ で作る）。体の周りを切り出して掛け、ヘッドの箱の中心を候補の先頭に置く（青）
import Foundation
import AVFoundation
import Vision
import CoreML
import AppKit

// MARK: - 解析用のグレースケール（表示向き・縮小・左上原点）

struct Gray {
    var w: Int
    var h: Int
    var px: [UInt8]
    @inline(__always) func at(_ x: Int, _ y: Int) -> Float { Float(px[y * w + x]) }
}

func grayFrame(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation, scale: Int) -> Gray {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let ws = CVPixelBufferGetWidthOfPlane(pb, 0), hs = CVPixelBufferGetHeightOfPlane(pb, 0)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let rotated = orientation == .right || orientation == .left
    let w = (rotated ? hs : ws) / scale, h = (rotated ? ws : hs) / scale
    var px = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let dx = x * scale, dy = y * scale
            let sx: Int, sy: Int
            switch orientation {
            case .right: sx = dy; sy = hs - 1 - dx
            case .left: sx = ws - 1 - dy; sy = dx
            case .down: sx = ws - 1 - dx; sy = hs - 1 - dy
            default: sx = dx; sy = dy
            }
            px[y * w + x] = base[sy * bpr + sx]
        }
    }
    return Gray(w: w, h: h, px: px)
}

/// 画素ごとの中央値（背景）と、中央値からの散らばり（中央絶対偏差。ノイズの目安）。frames は同じ大きさ
struct Background {
    var median: Gray
    var spread: [Float]
}

func medianBackground(_ frames: [Gray]) -> Background {
    let w = frames[0].w, h = frames[0].h
    var px = [UInt8](repeating: 0, count: w * h), spread = [Float](repeating: 0, count: w * h)
    var column = [UInt8](repeating: 0, count: frames.count), dev = [Int](repeating: 0, count: frames.count)
    for i in 0..<(w * h) {
        for (k, f) in frames.enumerated() { column[k] = f.px[i] }
        column.sort()
        let m = column[column.count / 2]
        px[i] = m
        for k in 0..<column.count { dev[k] = abs(Int(column[k]) - Int(m)) }
        dev.sort()
        spread[i] = Float(dev[dev.count / 2])
    }
    return Background(median: Gray(w: w, h: h, px: px), spread: spread)
}

/// 動いている画素のマスク。「前のフレームとも次のフレームとも違う」画素（いま動いている物だけが残り、残像や静止した線は消える。Gehrig ら 2003）に、
/// 背景（中央値）から離れた画素（トップで止まっているヘッドも残す）を足す。閾値はその画素のノイズ（散らばり）に応じる。少し膨らませて線の周りも含める
func motionMask(prev: Gray?, cur g: Gray, next: Gray?, background: Background, dilate: Int) -> [Bool] {
    let w = g.w, h = g.h
    // 露出の揺れ（夜の自動露出）を、画面全体の背景との差の中央値として引く
    var diffs: [Float] = []
    diffs.reserveCapacity(w * h / 16)
    for i in Swift.stride(from: 0, to: w * h, by: 16) { diffs.append(Float(g.px[i]) - Float(background.median.px[i])) }
    diffs.sort()
    let exposureShift = diffs.isEmpty ? 0 : diffs[diffs.count / 2]
    var raw = [Bool](repeating: false, count: w * h)
    for i in 0..<(w * h) {
        let noise = background.spread[i]
        let frameThreshold = max(10, 3.5 * noise + 4)
        let c = Float(g.px[i])
        let movingNow = (prev.map { abs(c - Float($0.px[i])) > frameThreshold } ?? true) && (next.map { abs(c - Float($0.px[i])) > frameThreshold } ?? true)
        let displaced = abs(c - exposureShift - Float(background.median.px[i])) > max(16, 5 * noise + 6)
        raw[i] = movingNow || displaced
    }
    guard dilate > 0 else { return raw }
    var out = raw
    for y in 0..<h {
        for x in 0..<w where raw[y * w + x] {
            for dy in -dilate...dilate {
                for dx in -dilate...dilate {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < w, yy < h { out[yy * w + xx] = true }
                }
            }
        }
    }
    return out
}

// MARK: - シャフトの探索（ヘッセ行列のリッジ + 手首を通る線の集計）

struct Shaft {
    var theta: Double      // 手首からの向き（ラジアン。画像座標で y 下向き）
    var length: Double     // 線の長さ（解析画素）
    var hits: Int          // 線に乗った画素の数
    var score: Double
    var end: CGPoint       // 線の終端（解析画素）
}

/// 画素ごとのリッジ（細い線）の強さと向き。ガウス平滑化した画像のヘッセ行列の固有値から求める。
/// 強さは局所の標準偏差で割って「その場のノイズの何倍か」にする（空に映る薄いシャフトを拾い、芝の模様を落とす）
struct RidgeMap {
    var w: Int
    var h: Int
    var strength: [Float]   // 正規化したリッジの強さ（0 以上）
    var angle: [Float]      // 線の向き（ラジアン、0..π）
}

func ridgeMap(_ g: Gray, sigma: Float = 1.6, boxRadius: Int = 10) -> RidgeMap {
    let w = g.w, h = g.h
    // ガウス平滑化（分離）
    let radius = Int(ceil(sigma * 2.5))
    var kernel = (0...(2 * radius)).map { exp(-Float(($0 - radius) * ($0 - radius)) / (2 * sigma * sigma)) }
    let ksum = kernel.reduce(0, +); kernel = kernel.map { $0 / ksum }
    var tmp = [Float](repeating: 0, count: w * h), blur = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
        var acc: Float = 0
        for k in -radius...radius { let xx = min(max(x + k, 0), w - 1); acc += Float(g.px[y * w + xx]) * kernel[k + radius] }
        tmp[y * w + x] = acc
    } }
    for y in 0..<h { for x in 0..<w {
        var acc: Float = 0
        for k in -radius...radius { let yy = min(max(y + k, 0), h - 1); acc += tmp[yy * w + x] * kernel[k + radius] }
        blur[y * w + x] = acc
    } }
    // 局所の標準偏差（積分画像）
    var sum = [Double](repeating: 0, count: (w + 1) * (h + 1)), sum2 = sum
    for y in 0..<h { for x in 0..<w {
        let v = Double(g.px[y * w + x])
        sum[(y + 1) * (w + 1) + x + 1] = v + sum[y * (w + 1) + x + 1] + sum[(y + 1) * (w + 1) + x] - sum[y * (w + 1) + x]
        sum2[(y + 1) * (w + 1) + x + 1] = v * v + sum2[y * (w + 1) + x + 1] + sum2[(y + 1) * (w + 1) + x] - sum2[y * (w + 1) + x]
    } }
    func localStd(_ x: Int, _ y: Int) -> Float {
        let x0 = max(x - boxRadius, 0), y0 = max(y - boxRadius, 0), x1 = min(x + boxRadius + 1, w), y1 = min(y + boxRadius + 1, h)
        let n = Double((x1 - x0) * (y1 - y0))
        let s = sum[y1 * (w + 1) + x1] - sum[y0 * (w + 1) + x1] - sum[y1 * (w + 1) + x0] + sum[y0 * (w + 1) + x0]
        let s2 = sum2[y1 * (w + 1) + x1] - sum2[y0 * (w + 1) + x1] - sum2[y1 * (w + 1) + x0] + sum2[y0 * (w + 1) + x0]
        return Float(max(s2 / n - (s / n) * (s / n), 0)).squareRoot()
    }
    var strength = [Float](repeating: 0, count: w * h), angle = [Float](repeating: 0, count: w * h)
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
        let i = y * w + x
        let ixx = blur[i - 1] - 2 * blur[i] + blur[i + 1]
        let iyy = blur[i - w] - 2 * blur[i] + blur[i + w]
        let ixy = (blur[i + w + 1] - blur[i + w - 1] - blur[i - w + 1] + blur[i - w - 1]) / 4
        // 固有値：λ1 が絶対値の大きい方（線に直交する方向の曲率）、λ2 が線に沿う方向
        let tr = ixx + iyy, det = ixx * iyy - ixy * ixy
        let disc = max(tr * tr / 4 - det, 0).squareRoot()
        let a = tr / 2 + disc, b = tr / 2 - disc
        let l1 = abs(a) >= abs(b) ? a : b, l2 = abs(a) >= abs(b) ? b : a
        // 線らしさ：直交方向の曲率が大きく、沿う方向は小さい
        let lineness = abs(l1) - abs(l2)
        guard lineness > 0 else { continue }
        strength[i] = lineness / (localStd(x, y) * 0.25 + 1.5)
        // λ1 の固有ベクトル（線に直交）から線の向きを出す
        let vx: Float, vy: Float
        if abs(ixy) > 1e-6 { vx = l1 - iyy; vy = ixy } else if abs(ixx) >= abs(iyy) { vx = 1; vy = 0 } else { vx = 0; vy = 1 }
        var th = atan2(vy, vx) + .pi / 2   // 直交ベクトルを 90° 回して線の向き
        if th < 0 { th += .pi }; if th >= .pi { th -= .pi }
        angle[i] = th
    } }
    return RidgeMap(w: w, h: h, strength: strength, angle: angle)
}

/// 手首 hand の近く（passDistance 画素以内）を通るリッジ画素を、画素自身の線の向き（2° 刻み）と手首から見た側で集計し、
/// 手首の近くから途切れずに最も長く強く続く線を選ぶ（腕は呼び出し側がマスクから除いている）
func detectShaft(_ ridge: RidgeMap, mask: [Bool], hand: CGPoint, rMin: Double, rMax: Double, minStrength: Float, passDistance: Double,
                 previous: CGPoint?, previousTheta: Double?, bodySize: Double) -> Shaft? {
    let w = ridge.w, h = ridge.h
    let x0 = max(Int(hand.x - rMax), 1), x1 = min(Int(hand.x + rMax), w - 2)
    let y0 = max(Int(hand.y - rMax), 1), y1 = min(Int(hand.y + rMax), h - 2)
    guard x0 < x1, y0 < y1 else { return nil }
    let binCount = 90   // 2° 刻み、向きは 0..π
    var bins = [[(Double, Float)]](repeating: [], count: binCount * 2)   // [向き][側]（側 0: +u、1: −u）
    for y in y0...y1 { for x in x0...x1 {
        let i = y * w + x
        let st = ridge.strength[i]
        guard st >= minStrength, mask[i] else { continue }
        let dx = Double(x) - hand.x, dy = Double(y) - hand.y
        let phi = Double(ridge.angle[i])
        let ux = cos(phi), uy = sin(phi)
        let along = dx * ux + dy * uy               // 線に沿った手首からの距離（符号が側）
        let perpendicular = abs(dx * uy - dy * ux)  // 線を延長したときの手首との距離
        guard perpendicular <= passDistance, abs(along) >= rMin, abs(along) <= rMax else { continue }
        let bin = min(Int(phi / .pi * Double(binCount)), binCount - 1)
        bins[bin * 2 + (along >= 0 ? 0 : 1)].append((abs(along), st))
    } }
    var best: Shaft? = nil
    for bin in 0..<binCount { for side in 0..<2 {
        var items = bins[bin * 2 + side] + bins[((bin + binCount - 1) % binCount) * 2 + side] + bins[((bin + 1) % binCount) * 2 + side]
        guard items.count >= 8 else { continue }
        let phi = (Double(bin) + 0.5) / Double(binCount) * .pi
        let th = side == 0 ? phi : phi + .pi
        let d = CGPoint(x: cos(th), y: sin(th))
        items.sort { $0.0 < $1.0 }
        guard items[0].0 - rMin <= 0.5 * bodySize else { continue }   // 線は手首の近くから始まる（根元は腕に隠れることがある）
        var lastR = items[0].0, weight: Float = 0, hits = 0
        for (r, st) in items {
            if r - lastR > 8 { break }   // 途切れは 8 画素まで
            lastR = r; weight += min(st, 3); hits += 1
        }
        let length = lastR - rMin
        guard length >= 0.4 * bodySize, Double(hits) >= 0.5 * length else { continue }
        let end = CGPoint(x: hand.x + d.x * lastR, y: hand.y + d.y * lastR)
        var score = Double(weight)
        if let previous {
            let jump = hypot(end.x - previous.x, end.y - previous.y) / bodySize
            score *= max(0.15, 1 - jump / 2.0)
        }
        if let previousTheta {
            var dth = abs(th - previousTheta); if dth > .pi { dth = 2 * .pi - dth }
            score *= max(0.3, 1 - dth / .pi)
        }
        if best == nil || score > best!.score {
            best = Shaft(theta: th, length: length, hits: hits, score: score, end: end)
        }
    } }
    return best
}


// MARK: - 黒いヘッドの塊（ドライバー向け）

struct Blob {
    var center: CGPoint    // 解析画素
    var area: Int
    var darkness: Float    // 背景よりどれだけ暗いか（平均）
}

/// 動いていて（mask）暗い画素の連結成分のうち、ヘッドらしい大きさのものを返す。手首の周り radius 画素の範囲だけ見る
func darkBlobs(_ g: Gray, mask: [Bool], background: Background, hand: CGPoint, radius: Double, bodySize: Double) -> [Blob] {
    let w = g.w, h = g.h
    let x0 = max(Int(hand.x - radius), 0), x1 = min(Int(hand.x + radius), w - 1)
    let y0 = max(Int(hand.y - radius), 0), y1 = min(Int(hand.y + radius), h - 1)
    guard x0 < x1, y0 < y1 else { return [] }
    var dark = [Bool](repeating: false, count: w * h)
    for y in y0...y1 { for x in x0...x1 {
        let i = y * w + x
        // 暗い（輝度 100 未満）うえに、その場所の背景よりノイズの 3 倍以上（最低 15）暗い（黒いヘッドは芝・空・マットのどれよりも暗い）
        dark[i] = mask[i] && Float(g.px[i]) < 100 && Float(background.median.px[i]) - Float(g.px[i]) > max(15, 3 * background.spread[i])
    } }
    let minArea = Int(0.05 * bodySize * 0.05 * bodySize), maxArea = Int(0.5 * bodySize * 0.5 * bodySize)
    var visited = [Bool](repeating: false, count: w * h)
    var blobs: [Blob] = []
    var stack: [Int] = []
    for y in y0...y1 { for x in x0...x1 {
        let start = y * w + x
        guard dark[start], !visited[start] else { continue }
        visited[start] = true; stack = [start]
        var count = 0, sx = 0, sy = 0, darkSum: Float = 0
        var bx0 = x, bx1 = x, by0 = y, by1 = y
        while let i = stack.popLast() {
            let cx = i % w, cy = i / w
            count += 1; sx += cx; sy += cy; darkSum += Float(background.median.px[i]) - Float(g.px[i])
            bx0 = min(bx0, cx); bx1 = max(bx1, cx); by0 = min(by0, cy); by1 = max(by1, cy)
            for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                guard nx >= x0, nx <= x1, ny >= y0, ny <= y1 else { continue }
                let j = ny * w + nx
                if dark[j], !visited[j] { visited[j] = true; stack.append(j) }
            }
        }
        guard count >= minArea, count <= maxArea, max(bx1 - bx0, by1 - by0) <= Int(0.6 * bodySize) else { continue }
        blobs.append(Blob(center: CGPoint(x: Double(sx) / Double(count), y: Double(sy) / Double(count)), area: count, darkness: darkSum / Float(count)))
    } }
    return blobs
}

/// 黒い塊の追跡の状態
struct BlobTracker {
    var position: CGPoint? = nil     // 直前に採用した位置（解析画素）
    var velocity = CGPoint.zero      // 1 フレームあたりの移動
    var lost = 0                     // 連続で見失ったフレーム数
    var stillFrames = 0              // 塊が止まったまま手首だけ動いているフレーム数（静止した暗い物に貼り付いた印）
    var lastHand: CGPoint? = nil
    /// 追跡していないときの、続けて現れている塊の候補（最初の位置・いまの位置・連続フレーム数）
    var pending: [(CGPoint, CGPoint, Int)] = []
    /// 採用した塊の手首からの距離 ÷ 体の大きさ（画像上のシャフト長の学習。予測の外れた塊を弾く）
    var ratios: [Double] = []

    /// 学習したシャフト長（体の大きさ単位）。80 パーセンタイルが投影で縮まないときの長さに近い。5 本集まるまでは nil
    var shaftLength: Double? {
        guard ratios.count >= 5 else { return nil }
        return ratios.sorted()[Int(Double(ratios.count - 1) * 0.8)]
    }

    /// 手首からの距離がシャフト長として妥当か（投影で縮むぶん下は 0.35 倍まで、上は 1.3 倍まで許す）
    /// NOTE: 学習したシャフト長で絞る案（0.35〜1.3 倍）は、後方視点でトップ付近の投影が短くなり正しい塊まで落とした（マキロイ 66% → 43%）ので使っていない
    func plausible(_ point: CGPoint, hand: CGPoint, bodySize: Double) -> Bool {
        let d = hypot(point.x - hand.x, point.y - hand.y) / bodySize
        return d >= 0.25 && d <= 3.0
    }

    /// 前フレームからの予測に最も近い塊を採る。予測が画面の外なら乗り移らずに待つ。予測から遠い塊しか無ければ見失い扱い（速度は減衰）。
    /// 追跡していないときは、シャフトの線の先端の塊か、手首より下で動き始めた塊（テークバック）で始める
    mutating func update(blobs: [Blob], hand: CGPoint, shaftEnd: CGPoint?, bodySize: Double, afterImpact: Bool, bodyBox: CGRect?,
                         frame: CGRect, nearStart: Bool) -> CGPoint? {
        let inRange = blobs.filter { plausible($0.center, hand: hand, bodySize: bodySize) }
        if let position {
            let predicted = CGPoint(x: position.x + velocity.x, y: position.y + velocity.y)
            let speed = hypot(velocity.x, velocity.y)
            let gate = max(0.5 * bodySize, 2.5 * speed)
            let inside = frame.insetBy(dx: 0.1 * bodySize, dy: 0.1 * bodySize).contains(predicted)
            if inside,
               let best = inRange.min(by: { hypot($0.center.x - predicted.x, $0.center.y - predicted.y) < hypot($1.center.x - predicted.x, $1.center.y - predicted.y) }),
               hypot(best.center.x - predicted.x, best.center.y - predicted.y) <= gate {
                // 静止した暗い物（バッグ・影）への貼り付きを切る：塊が止まったまま手首だけ動いている、
                // またはインパクト後に塊が止まっている（トップでは止まってよい。インパクト後はフィニッシュまで止まらない）
                let moved = hypot(best.center.x - position.x, best.center.y - position.y)
                let handMoved = lastHand.map { hypot(hand.x - $0.x, hand.y - $0.y) } ?? 0
                let still = moved < 0.03 * bodySize && (handMoved > 0.03 * bodySize || afterImpact)
                stillFrames = still ? stillFrames + 1 : 0
                lastHand = hand
                if stillFrames > 6 { self.position = nil; velocity = .zero; stillFrames = 0; return nil }
                velocity = CGPoint(x: (best.center.x - position.x) * 0.7 + velocity.x * 0.3, y: (best.center.y - position.y) * 0.7 + velocity.y * 0.3)
                self.position = best.center; lost = 0
                ratios.append(hypot(best.center.x - hand.x, best.center.y - hand.y) / bodySize)
                return best.center
            }
            lastHand = hand
            lost += 1
            // 画面の外へ出たと見ているときは、予測で追い続ける（戻ってきたところで拾う）
            self.position = inside ? position : predicted
            velocity = CGPoint(x: velocity.x * (inside ? 0.8 : 0.95), y: velocity.y * (inside ? 0.8 : 0.95))
            if lost > (inside ? 6 : 15) { self.position = nil; velocity = .zero }
            return nil
        }
        // 追跡の開始 (a)：シャフトの線の先端から 0.4 体分以内の塊
        if let shaftEnd, let best = inRange.min(by: { hypot($0.center.x - shaftEnd.x, $0.center.y - shaftEnd.y) < hypot($1.center.x - shaftEnd.x, $1.center.y - shaftEnd.y) }),
           hypot(best.center.x - shaftEnd.x, best.center.y - shaftEnd.y) <= 0.4 * bodySize {
            begin(at: best.center, hand: hand, bodySize: bodySize)
            return best.center
        }
        // 追跡の開始 (b)：スイングの始まりに、手首より下で体の外、3 フレーム続けて現れて動いた塊（テークバックのヘッド）
        guard nearStart else { pending = []; lastHand = hand; return nil }
        let candidates = inRange.filter { b in
            b.center.y > hand.y + 0.3 * bodySize && (bodyBox.map { !$0.insetBy(dx: -0.15 * bodySize, dy: -0.15 * bodySize).contains(b.center) } ?? true)
        }
        var next: [(CGPoint, CGPoint, Int)] = []
        for b in candidates {
            if let old = pending.first(where: { hypot($0.1.x - b.center.x, $0.1.y - b.center.y) <= 0.4 * bodySize }) {
                next.append((old.0, b.center, old.2 + 1))
            } else {
                next.append((b.center, b.center, 1))
            }
        }
        pending = next
        if let start = pending.filter({ $0.2 >= 3 && hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) >= 0.08 * bodySize })
            .max(by: { hypot($0.1.x - hand.x, $0.1.y - hand.y) < hypot($1.1.x - hand.x, $1.1.y - hand.y) }) {
            begin(at: start.1, hand: hand, bodySize: bodySize)
            return start.1
        }
        lastHand = hand
        return nil
    }

    private mutating func begin(at point: CGPoint, hand: CGPoint, bodySize: Double) {
        position = point; velocity = .zero; lost = 0; stillFrames = 0; lastHand = hand; pending = []
        ratios.append(hypot(point.x - hand.x, point.y - hand.y) / bodySize)
    }
}

// MARK: - 動画の読み出しと追跡

struct HeadSample {
    var time: Double
    var hand: CGPoint?        // 正規化（左上原点）
    var head: CGPoint?        // シャフトの線の先端
    var blob: CGPoint?        // 黒い塊の追跡（正規化）
    var estimate: CGPoint?    // 塊が無いとき、線の向き × 学習したシャフト長で置いた推定（正規化）
    var hypotheses: [CGPoint] = []   // このフレームのヘッドの候補すべて（塊・線の先端・推定。正規化）。軌跡の当てはめに使う
    var modelled: CGPoint?    // 軌跡モデル（極座標の多項式）で決めた位置（正規化）。候補が無いフレームは曲線上の補間
    var length: Double        // 体の大きさ（腰〜首）に対する線の長さ
    var hits: Int
    var detectedBox: CGRect?  // 検出器（--model）のヘッドの箱（正規化・左上原点）
    var detectedConfidence: Float = 0
    var detected: CGPoint? { detectedBox.map { CGPoint(x: $0.midX, y: $0.midY) } }
}

// MARK: - Core ML の検出器

/// Create ML で学習したクラブ（club）とヘッド（club_head）の検出器。
/// ヘッドは 1080p で 20〜40 画素と小さく、モデルの入力は 299 画素四方に縮むので、姿勢の体の枠を広げた領域だけを切り出して掛ける
struct Detector {
    struct Boxes {   // 正規化・左下原点（Vision の座標）
        var head: CGRect?; var headConfidence: Float = 0
        var club: CGRect?; var clubConfidence: Float = 0
    }
    let model: VNCoreMLModel

    init(path: String) throws {
        var url = URL(fileURLWithPath: path)
        if url.pathExtension == "mlmodel" { url = try MLModel.compileModel(at: url) }
        model = try VNCoreMLModel(for: MLModel(contentsOf: url))
    }

    /// 体の枠（正規化・左下原点）の周りに体の高さの 0.8 倍ずつ広げた領域。クラブの長さは体の高さの 0.65 倍ほどなので、伸ばした先まで入る
    static func region(around body: CGRect) -> CGRect {
        let margin = body.height * 0.8
        return body.insetBy(dx: -margin, dy: -margin).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func detect(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, roi: CGRect?) -> Boxes {
        let request = VNCoreMLRequest(model: model)
        // NOTE: Create ML の検出器は必ず scaleFill で掛ける。既定の centerCrop（と scaleFit）では、返る箱の座標に切り落とし分の補正が
        // 二重に掛かり、縦長の動画では y が 0.56 倍に縮んで返る（2026-09-13、macroy_behind の 1 フレームで 3 通りを比較して確認。
        // 学習画像も 640×640 に引き伸ばしてあるので、領域を正方形に引き伸ばす scaleFill がモデルの前提とも合う）
        request.imageCropAndScaleOption = .scaleFill
        if let roi, !roi.isEmpty { request.regionOfInterest = roi }
        var boxes = Boxes()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        guard (try? handler.perform([request])) != nil, let results = request.results as? [VNRecognizedObjectObservation] else { return boxes }
        for observation in results {
            guard let label = observation.labels.first else { continue }
            var box = observation.boundingBox
            // 切り出し領域を指定したときの箱はその領域の中の座標なので、フレーム全体の座標に戻す
            if let roi = request.regionOfInterest as CGRect?, roi != CGRect(x: 0, y: 0, width: 1, height: 1) {
                box = CGRect(x: roi.minX + box.minX * roi.width, y: roi.minY + box.minY * roi.height, width: box.width * roi.width, height: box.height * roi.height)
            }
            switch label.identifier {
            case "club_head", "1": if label.confidence > boxes.headConfidence { boxes.head = box; boxes.headConfidence = label.confidence }
            case "club", "0": if label.confidence > boxes.clubConfidence { boxes.club = box; boxes.clubConfidence = label.confidence }
            default: break
            }
        }
        return boxes
    }
}

/// 腕の線分（手首 → 肘、肘 → 肩。正規化座標・左上原点）。シャフト探索でこの帯を除くために使う
struct ArmFrame {
    var time: Double
    var segments: [(CGPoint, CGPoint)]
}

func armFrames(video: SwingAnalyzer.Video) throws -> [ArmFrame] {
    var frames: [ArmFrame] = []
    try PoseTracker.forEachTrackedPerson(asset: video.asset, videoTrack: video.track, frameRate: video.frameRate, orientation: video.orientation) { time, person in
        var segments: [(CGPoint, CGPoint)] = []
        if let person {
            func pt(_ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let q = try? person.recognizedPoint(j), q.confidence >= 0.3 else { return nil }
                return CGPoint(x: q.location.x, y: 1 - q.location.y)
            }
            typealias J = VNHumanBodyPoseObservation.JointName
            let arms: [(J, J, J)] = [(.leftWrist, .leftElbow, .leftShoulder), (.rightWrist, .rightElbow, .rightShoulder)]
            for (wrist, elbow, shoulder) in arms {
                if let w = pt(wrist), let e = pt(elbow) { segments.append((w, e)) }
                if let e = pt(elbow), let sh = pt(shoulder) { segments.append((e, sh)) }
            }
        }
        frames.append(ArmFrame(time: time, segments: segments))
    }
    return frames
}

/// 腕の帯（線分から corridor 画素以内）をマスクから外す。手首の周り keep 画素以内は残す（シャフトの根元）
func excludeArms(_ mask: inout [Bool], w: Int, h: Int, segments: [(CGPoint, CGPoint)], hand: CGPoint, corridor: Double, keep: Double) {
    for (a, b) in segments {
        let ax = a.x * Double(w), ay = a.y * Double(h), bx = b.x * Double(w), by = b.y * Double(h)
        let x0 = max(Int(min(ax, bx) - corridor), 0), x1 = min(Int(max(ax, bx) + corridor), w - 1)
        let y0 = max(Int(min(ay, by) - corridor), 0), y1 = min(Int(max(ay, by) + corridor), h - 1)
        guard x0 <= x1, y0 <= y1 else { continue }
        let vx = bx - ax, vy = by - ay, len2 = max(vx * vx + vy * vy, 1e-6)
        for y in y0...y1 { for x in x0...x1 {
            let px = Double(x), py = Double(y)
            if hypot(px - hand.x, py - hand.y) <= keep { continue }
            let tt = min(max(((px - ax) * vx + (py - ay) * vy) / len2, 0), 1)
            let dx = px - (ax + tt * vx), dy = py - (ay + tt * vy)
            if dx * dx + dy * dy <= corridor * corridor { mask[y * w + x] = false }
        } }
    }
}

func track(url: URL) async throws -> (SwingAnalysisResult, [HeadSample], Int, Int) {
    let result = try await SwingAnalyzer.analyze(url: url)
    let p = result.phases
    let video = try await SwingAnalyzer.loadVideo(url: url)
    let arms = try armFrames(video: video)
    let reader = try AVAssetReader(asset: video.asset)
    let output = AVAssetReaderTrackOutput(track: video.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    // 姿勢は SwingAnalyzer が 30fps 相当で取っているので、同じ間引きのフレームを使う。スイング区間の前後 0.3 秒だけ読む
    let stride = max(1, Int((video.frameRate / analysisRate).rounded()))
    var grays: [(Double, Gray)] = []
    var detections: [Detector.Boxes?] = []   // grays と同じ並び。--model が無ければ nil
    var index = 0
    var readPoseIndex = 0
    while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
        defer { index += 1 }
        if index % stride != 0 { continue }
        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard t >= p.address - 0.3, t <= p.finish + 0.3, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
        let scale = max(1, Int((Double(max(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))) / 640.0).rounded()))
        grays.append((t, grayFrame(pb, orientation: video.orientation, scale: scale)))
        if let detector {
            // 検出器は元の解像度のフレームに掛ける（縮小前）。切り出し領域はそのフレームに最も近い姿勢の体の枠から
            while readPoseIndex + 1 < result.pose.frames.count, result.pose.frames[readPoseIndex + 1].time <= t + 1e-3 { readPoseIndex += 1 }
            let pose = result.pose.frames[readPoseIndex]
            let roi = abs(pose.time - t) < 0.1 ? pose.bodyBounds.map(Detector.region(around:)) : nil
            detections.append(detector.detect(pb, orientation: video.orientation, roi: roi))
        } else {
            detections.append(nil)
        }
    }
    guard let first = grays.first else { return (result, [], 0, 0) }
    let w = first.1.w, h = first.1.h
    // 背景：区間全体から 40 枚ほど等間隔に取った中央値
    let step = max(1, grays.count / 40)
    let background = medianBackground(Swift.stride(from: 0, to: grays.count, by: step).map { grays[$0].1 })
    let torso = result.pose.torsoHeight ?? 0.2
    let sPx = torso * Double(h)
    var samples: [HeadSample] = []
    var previous: CGPoint? = nil
    var previousTheta: Double? = nil
    var blobTracker = BlobTracker()
    var poseIndex = 0
    for (index, (t, g)) in grays.enumerated() {
        while poseIndex + 1 < result.pose.frames.count, result.pose.frames[poseIndex + 1].time <= t + 1e-3 { poseIndex += 1 }
        let pose = result.pose.frames[poseIndex]
        // 検出器のヘッドの箱（Vision の左下原点 → 左上原点）
        let detection = detections[index]
        let detectedBox = detection?.head.map { CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) }
        let detectedCenter = detectedBox.map { CGPoint(x: $0.midX, y: $0.midY) }
        guard let wrist = pose.wrist, abs(pose.time - t) < 0.1 else {
            samples.append(HeadSample(time: t, hand: nil, head: nil, blob: nil, estimate: nil, hypotheses: detectedCenter.map { [$0] } ?? [], modelled: nil,
                                      length: 0, hits: 0, detectedBox: detectedBox, detectedConfidence: detection?.headConfidence ?? 0))
            previous = nil; previousTheta = nil; continue
        }
        let hand = CGPoint(x: wrist.x * Double(w), y: (1 - wrist.y) * Double(h))
        var mask = motionMask(prev: index > 0 ? grays[index - 1].1 : nil, cur: g, next: index + 1 < grays.count ? grays[index + 1].1 : nil, background: background, dilate: 2)
        let ridge = ridgeMap(g)
        let arm = arms.min { abs($0.time - t) < abs($1.time - t) }
        excludeArms(&mask, w: w, h: h, segments: arm?.segments ?? [], hand: hand, corridor: 0.16 * sPx, keep: 0.35 * sPx)
        let shaft = detectShaft(ridge, mask: mask, hand: hand, rMin: 0.2 * sPx, rMax: 3.0 * sPx, minStrength: minStrength, passDistance: 8,
                                previous: previous, previousTheta: previousTheta ?? (.pi / 2), bodySize: sPx)
        if debugTime.map({ abs($0 - t) < 0.02 }) ?? false {
            func writeGray(_ values: [UInt8], _ name: String) {
                let provider = CGDataProvider(data: Data(values) as CFData)!
                let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
            }
            writeGray(g.px, "debug_gray.png")
            writeGray(mask.map { $0 ? 255 : 0 }, "debug_mask.png")
            writeGray(ridge.strength.map { UInt8(min(max($0 / 1.5 * 255, 0), 255)) }, "debug_ridge.png")
            writeGray((0..<(w * h)).map { (mask[$0] && ridge.strength[$0] >= minStrength) ? 255 : 0 }, "debug_candidates.png")
            let st = (0..<(w * h)).filter { mask[$0] }.map { ridge.strength[$0] }.sorted()
            func pct(_ q: Double) -> Float { st.isEmpty ? 0 : st[Int(Double(st.count - 1) * q)] }
            print(String(format: "  [debug t=%.2f] mask %.0f%%  strength p50=%.2f p90=%.2f p99=%.2f  hand=(%d,%d) s=%.0fpx  arms=%@  shaft=%@", t,
                         Double(st.count) / Double(w * h) * 100, pct(0.5), pct(0.9), pct(0.99), Int(hand.x), Int(hand.y), sPx,
                         "\(arm?.segments.count ?? 0) segs",
                         shaft.map { String(format: "θ=%.0f° len=%.2fs hits=%d", $0.theta * 180 / .pi, $0.length / sPx, $0.hits) } ?? "none"))
        }
        previous = shaft?.end
        if let shaft { previousTheta = shaft.theta }
        let blobs = darkBlobs(g, mask: mask, background: background, hand: hand, radius: 3.2 * sPx, bodySize: sPx)
        let box = pose.bodyBounds.map { CGRect(x: $0.minX * Double(w), y: (1 - $0.maxY) * Double(h), width: $0.width * Double(w), height: $0.height * Double(h)) }
        let blob = blobTracker.update(blobs: blobs, hand: hand, shaftEnd: shaft?.end, bodySize: sPx, afterImpact: t > p.impact, bodyBox: box,
                                      frame: CGRect(x: 0, y: 0, width: w, height: h), nearStart: t < p.address + 0.8)
        var estimate: CGPoint? = nil
        if blob == nil, let shaft, let ratio = blobTracker.shaftLength {
            let q = CGPoint(x: hand.x + cos(shaft.theta) * ratio * sPx, y: hand.y + sin(shaft.theta) * ratio * sPx)
            if q.x >= 0, q.y >= 0, q.x < Double(w), q.y < Double(h) { estimate = q }
        }
        func norm(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x / Double(w), y: q.y / Double(h)) }
        var hypotheses: [CGPoint] = []
        if let detectedCenter { hypotheses.append(detectedCenter) }
        if let blob { hypotheses.append(norm(blob)) }
        if let shaft { hypotheses.append(norm(shaft.end)) }
        if let estimate { hypotheses.append(norm(estimate)) }
        let others = blobs.filter { blobTracker.plausible($0.center, hand: hand, bodySize: sPx) }
            .sorted { $0.area > $1.area }.prefix(4 - min(hypotheses.count, 3)).map { norm($0.center) }
        hypotheses.append(contentsOf: others)
        samples.append(HeadSample(time: t, hand: norm(hand), head: shaft.map { norm($0.end) }, blob: blob.map(norm), estimate: estimate.map(norm),
                                  hypotheses: hypotheses, modelled: nil, length: (shaft?.length ?? 0) / sPx, hits: shaft?.hits ?? 0,
                                  detectedBox: detectedBox, detectedConfidence: detection?.headConfidence ?? 0))
    }
    return (result, samples, w, h)
}


// MARK: - 軌跡モデル（極座標の多項式。Gehrig ら BMVC 2003）

/// 中心 center からの極座標。β は真上を 0 として時計回り（画像座標は y が下向き）
func polar(_ q: CGPoint, center: CGPoint, aspect: Double) -> (beta: Double, rho: Double) {
    let dx = (q.x - center.x) * aspect, dy = q.y - center.y
    return (atan2(dx, -dy), hypot(dx, dy))
}

/// β を、目安 reference に最も近い 2π の分枝に置く
func unwrap(_ beta: Double, near reference: Double) -> Double {
    var b = beta
    while b - reference > .pi { b -= 2 * .pi }
    while reference - b > .pi { b += 2 * .pi }
    return b
}

/// 最小二乗で ρ(u) = Σ c_k u^k を解く（u は正規化した β）。正規方程式をガウスの消去で解く
func fitPolynomial(_ points: [(Double, Double)], degree: Int) -> [Double]? {
    let n = degree + 1
    var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
    for (u, r) in points {
        var pow = [Double](repeating: 1, count: 2 * n)
        for k in 1..<(2 * n) { pow[k] = pow[k - 1] * u }
        for i in 0..<n { for j in 0..<n { a[i][j] += pow[i + j] }; a[i][n] += pow[i] * r }
    }
    for i in 0..<n {
        var pivot = i
        for r in i..<n where abs(a[r][i]) > abs(a[pivot][i]) { pivot = r }
        if abs(a[pivot][i]) < 1e-12 { return nil }
        a.swapAt(i, pivot)
        for r in 0..<n where r != i {
            let f = a[r][i] / a[i][i]
            if f != 0 { for c in i...n { a[r][c] -= f * a[i][c] } }
        }
    }
    return (0..<n).map { a[$0][n] / a[$0][$0] }
}

func evalPolynomial(_ c: [Double], _ u: Double) -> Double {
    var r = 0.0, p = 1.0
    for k in c { r += k * p; p *= u }
    return r
}

/// 1 区間（上げ or 下げ）の候補に、ρ(β) の多項式を RANSAC で当てはめ、各フレームの位置を決める。
/// - hypotheses: フレームごとの候補（時刻順）。β は連続するように unwrap 済み
/// - 戻り値：フレームごとの (位置, 実測か) 。候補がインライアなら実測、無ければ曲線上の補間（β は時間で線形補間）
func fitSegment(times: [Double], hypotheses: [[(beta: Double, rho: Double)]], degree: Int, threshold: Double, iterations: Int,
                center: CGPoint, aspect: Double, sign: Double) -> [(CGPoint, Bool)?] {
    let frames = hypotheses.indices.filter { !hypotheses[$0].isEmpty }
    guard frames.count >= degree + 2 else { return Array(repeating: nil, count: times.count) }
    let allBetas = hypotheses.flatMap { $0.map(\.beta) }
    let betaMid = (allBetas.min()! + allBetas.max()!) / 2, betaHalf = max((allBetas.max()! - allBetas.min()!) / 2, 1e-3)
    func u(_ beta: Double) -> Double { (beta - betaMid) / betaHalf }
    var best: (coefficients: [Double], support: Int) = ([], 0)
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<iterations {
        // 別々のフレームから degree + 2 個の候補を選び、時刻順に β が増えるものだけ使う
        let chosen = frames.shuffled(using: &rng).prefix(degree + 2).sorted()
        var pts: [(Double, Double)] = []
        var lastBeta = -Double.infinity
        var ok = true
        for f in chosen {
            let hyp = hypotheses[f].randomElement(using: &rng)!
            if hyp.beta <= lastBeta { ok = false; break }
            lastBeta = hyp.beta
            pts.append((u(hyp.beta), hyp.rho))
        }
        guard ok, let c = fitPolynomial(pts, degree: degree) else { continue }
        // 支持：曲線に近い候補を持つフレームのうち、時刻順に β が増え続ける最長の連なりの長さ
        var support = 0, run = 0, runBeta = -Double.infinity
        for f in frames {
            let near = hypotheses[f].filter { abs(evalPolynomial(c, u($0.beta)) - $0.rho) <= threshold }.map(\.beta)
            if let b = near.filter({ $0 > runBeta }).min() { run += 1; runBeta = b } else if !near.isEmpty { run = 1; runBeta = near.min()! }
            support = max(support, run)
        }
        if support > best.support { best = (c, support) }
    }
    guard best.support >= degree + 2 else { return Array(repeating: nil, count: times.count) }
    // インライアで当てはめ直す
    var inliers: [(Double, Double)] = []
    var inlierBeta = [Double?](repeating: nil, count: times.count)
    var lastInlierBeta = -Double.infinity
    for f in frames {
        let near = hypotheses[f].filter { abs(evalPolynomial(best.coefficients, u($0.beta)) - $0.rho) <= threshold && $0.beta > lastInlierBeta }
        if let h = near.min(by: { abs(evalPolynomial(best.coefficients, u($0.beta)) - $0.rho) < abs(evalPolynomial(best.coefficients, u($1.beta)) - $1.rho) }) {
            inliers.append((u(h.beta), h.rho)); inlierBeta[f] = h.beta; lastInlierBeta = h.beta
        }
    }
    let c = fitPolynomial(inliers, degree: degree) ?? best.coefficients
    func point(beta: Double) -> CGPoint {
        let rho = evalPolynomial(c, u(beta))
        let actual = sign * beta   // 当てはめでは増える向きに揃えていたので、元の向きに戻す
        return CGPoint(x: center.x + sin(actual) * rho / aspect, y: center.y - cos(actual) * rho)
    }
    var out = [(CGPoint, Bool)?](repeating: nil, count: times.count)
    for f in times.indices {
        if let b = inlierBeta[f] {
            out[f] = (point(beta: b), true)
        } else if let prev = (0..<f).last(where: { inlierBeta[$0] != nil }), let next = ((f + 1)..<times.count).first(where: { inlierBeta[$0] != nil }) {
            let frac = (times[f] - times[prev]) / max(times[next] - times[prev], 1e-6)
            out[f] = (point(beta: inlierBeta[prev]! + (inlierBeta[next]! - inlierBeta[prev]!) * frac), false)
        }
    }
    return out
}

/// 上げ（アドレス〜トップ）と下げ（トップ〜フィニッシュ）を別々に当てはめる。
/// 中心はその区間のヘッドの候補（追跡した塊があればそれ）の平均。β は前のフレームの候補の中央値に続く枝で外し、増える向きに揃える
func fitTrajectory(_ samples: inout [HeadSample], phases: PhaseSet, aspect: Double, bodySize: Double) -> (upSupport: Int, downSupport: Int) {
    var supports = (0, 0)
    for (segment, degree) in [(phases.address...phases.top, 4), (phases.top...phases.finish, 4)] {
        let idx = samples.indices.filter { segment.contains(samples[$0].time) }
        guard !idx.isEmpty else { continue }
        let anchors = idx.compactMap { samples[$0].blob ?? samples[$0].hypotheses.first }
        guard anchors.count >= degree + 2 else { continue }
        let center = CGPoint(x: anchors.map(\.x).reduce(0, +) / Double(anchors.count), y: anchors.map(\.y).reduce(0, +) / Double(anchors.count))
        // 候補の β を、前のフレームの候補の中央値に最も近い枝に置く（時間方向に連続にする）
        var hyps: [[(beta: Double, rho: Double)]] = []
        var reference: Double? = nil
        for i in idx {
            let raw = samples[i].hypotheses.map { polar($0, center: center, aspect: aspect) }
            let placed = raw.map { pr -> (beta: Double, rho: Double) in
                (beta: reference.map { r in unwrap(pr.beta, near: r) } ?? pr.beta, rho: pr.rho)
            }
            hyps.append(placed)
            if !placed.isEmpty {
                let betas = placed.map(\.beta).sorted()
                reference = betas[betas.count / 2]
            }
        }
        // 増える向きに揃える：前半 1/4 と後半 1/4 の候補の β の中央値を比べる（1 フレームの外れ値に左右されないように）
        let firsts = hyps.compactMap { $0.first?.beta }
        let quarter = max(firsts.count / 4, 1)
        func median(_ a: ArraySlice<Double>) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let sign: Double = median(firsts.suffix(quarter)) >= median(firsts.prefix(quarter)) ? 1 : -1
        let signed = hyps.map { $0.map { (beta: sign * $0.beta, rho: $0.rho) } }
        if let dump = ProcessInfo.processInfo.environment["CLUB_POLAR_DUMP"] {
            var text = "t,beta0,rho0,count\n"
            for (k, i) in idx.enumerated() {
                let h = signed[k].first
                text += String(format: "%.3f,%@,%@,%d\n", samples[i].time, h.map { String(format: "%.3f", $0.beta) } ?? "", h.map { String(format: "%.3f", $0.rho) } ?? "", signed[k].count)
            }
            try? text.write(toFile: dump + "-\(segment.lowerBound == phases.address ? "up" : "down").csv", atomically: true, encoding: .utf8)
        }
        let fitted = fitSegment(times: idx.map { samples[$0].time }, hypotheses: signed, degree: degree, threshold: 0.35 * bodySize, iterations: 800,
                                center: center, aspect: aspect, sign: sign)
        var support = 0
        for (k, i) in idx.enumerated() {
            guard let (q, measured) = fitted[k] else { continue }
            samples[i].modelled = q
            if measured { support += 1 }
        }
        if segment.lowerBound == phases.address { supports.0 = support } else { supports.1 = support }
    }
    return supports
}

// MARK: - 後処理（外れ値除去と補間）

/// 前後 window 秒以内の検出点のどちらからも maxJump（体の大きさ単位）以上離れた点を捨て、gap 秒以内の欠けを線形補間する
func smooth(_ samples: [HeadSample], bodySize: Double, window: Double, maxJump: Double, gap: Double) -> [HeadSample] {
    var out = samples
    let detected = samples.enumerated().filter { $0.element.head != nil }
    for (k, (i, s)) in detected.enumerated() {
        guard let head = s.head else { continue }
        func near(_ j: Int) -> Bool {
            guard j >= 0, j < detected.count, let other = detected[j].element.head, abs(detected[j].element.time - s.time) <= window else { return false }
            return hypot(head.x - other.x, head.y - other.y) <= maxJump * bodySize
        }
        if !near(k - 1) && !near(k + 1) { out[i].head = nil }
    }
    var last: (Int, CGPoint)? = nil
    for i in out.indices {
        if let head = out[i].head {
            if let (j, prev) = last, i - j > 1, out[i].time - out[j].time <= gap {
                for m in (j + 1)..<i {
                    let f = (out[m].time - out[j].time) / (out[i].time - out[j].time)
                    out[m].head = CGPoint(x: prev.x + (head.x - prev.x) * f, y: prev.y + (head.y - prev.y) * f)
                }
            }
            last = (i, head)
        }
    }
    return out
}

// MARK: - 出力

func overlay(url: URL, time: Double, samples: [HeadSample], upTo: Double, to file: URL) throws {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    gen.maximumSize = CGSize(width: 1080, height: 1080)
    let cg = try gen.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 6000), actualTime: nil)
    let W = cg.width, H = cg.height
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * Double(W), y: (1 - p.y) * Double(H)) }   // CG は左下原点
    let heads = samples.filter { $0.time <= upTo + 1e-6 }.compactMap { $0.head }
    ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 1, alpha: 0.9)); ctx.setLineWidth(3)
    if let firstHead = heads.first {
        ctx.move(to: pt(firstHead)); for q in heads.dropFirst() { ctx.addLine(to: pt(q)) }; ctx.strokePath()
    }
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 0.9))
    for q in heads { ctx.fillEllipse(in: CGRect(origin: pt(q), size: .zero).insetBy(dx: -3, dy: -3)) }
    // 黒い塊の追跡（橙）
    let blobs = samples.filter { $0.time <= upTo + 1e-6 }.compactMap { $0.blob }
    ctx.setStrokeColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 0.95)); ctx.setLineWidth(3)
    if let firstBlob = blobs.first {
        ctx.move(to: pt(firstBlob)); for q in blobs.dropFirst() { ctx.addLine(to: pt(q)) }; ctx.strokePath()
    }
    ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 0.95))
    for q in blobs { ctx.fillEllipse(in: CGRect(origin: pt(q), size: .zero).insetBy(dx: -4, dy: -4)) }
    let estimates = samples.filter { $0.time <= upTo + 1e-6 }.compactMap { $0.estimate }
    ctx.setFillColor(CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 0.9))
    for q in estimates { ctx.fillEllipse(in: CGRect(origin: pt(q), size: .zero).insetBy(dx: -4, dy: -4)) }
    // 検出器のヘッド（青）。そのコマの箱も描く
    let detected = samples.filter { $0.time <= upTo + 1e-6 }.compactMap { $0.detected }
    ctx.setStrokeColor(CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 0.95)); ctx.setLineWidth(3)
    if let firstDetected = detected.first {
        ctx.move(to: pt(firstDetected)); for q in detected.dropFirst() { ctx.addLine(to: pt(q)) }; ctx.strokePath()
    }
    ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 0.95))
    for q in detected { ctx.fillEllipse(in: CGRect(origin: pt(q), size: .zero).insetBy(dx: -4, dy: -4)) }
    if let s = samples.min(by: { abs($0.time - time) < abs($1.time - time) }), abs(s.time - time) < 0.05, let box = s.detectedBox {
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 1)); ctx.setLineWidth(3)
        ctx.stroke(CGRect(x: box.minX * Double(W), y: (1 - box.maxY) * Double(H), width: box.width * Double(W), height: box.height * Double(H)))
    }
    // 軌跡モデル（白）
    let modelled = samples.filter { $0.time <= upTo + 1e-6 }.compactMap { $0.modelled }
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)); ctx.setLineWidth(4)
    if let firstM = modelled.first {
        ctx.move(to: pt(firstM)); for q in modelled.dropFirst() { ctx.addLine(to: pt(q)) }; ctx.strokePath()
    }
    if let s = samples.min(by: { abs($0.time - time) < abs($1.time - time) }), abs(s.time - time) < 0.05, let b = s.blob {
        ctx.setStrokeColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 1)); ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(origin: pt(b), size: .zero).insetBy(dx: -14, dy: -14))
    }
    if let s = samples.min(by: { abs($0.time - time) < abs($1.time - time) }), abs(s.time - time) < 0.05, let hand = s.hand {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1)); ctx.fillEllipse(in: CGRect(origin: pt(hand), size: .zero).insetBy(dx: -7, dy: -7))
        if let head = s.head {
            ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 1, alpha: 0.9)); ctx.setLineWidth(2)
            ctx.move(to: pt(hand)); ctx.addLine(to: pt(head)); ctx.strokePath()
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fillEllipse(in: CGRect(origin: pt(head), size: .zero).insetBy(dx: -9, dy: -9))
        }
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: file)
}

let args = CommandLine.arguments.dropFirst()
guard args.count >= 2 else { print("usage: clubtrack <video> <outdir>"); exit(1) }
let url = URL(fileURLWithPath: args[args.startIndex])
let outDir = URL(fileURLWithPath: args[args.startIndex + 1])
let debugTime = args.firstIndex(of: "--debug").flatMap { Double(args[$0 + 1]) }
let minStrength: Float = args.firstIndex(of: "--min").flatMap { Float(args[$0 + 1]) } ?? 0.5
let analysisRate: Double = args.firstIndex(of: "--rate").flatMap { Double(args[$0 + 1]) } ?? 30
let detector: Detector? = try args.firstIndex(of: "--model").map { try Detector(path: args[$0 + 1]) }
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let done = DispatchSemaphore(value: 0)
Task {
    do {
        let started = Date()
        var (result, samples, w, h) = try await track(url: url)
        let p = result.phases
        let supports = fitTrajectory(&samples, phases: p, aspect: Double(w) / Double(h), bodySize: result.pose.torsoHeight ?? 0.2)
        let modelledCount = samples.filter { $0.time >= p.address && $0.time <= p.finish && $0.modelled != nil }.count
        print(String(format: "# %@ fps=%.1f 解析 %dx%d  A=%.2f T=%.2f I=%.2f F=%.2f  (%.1fs)", url.lastPathComponent, result.frameRate, w, h, p.address, p.top, p.impact, p.finish, Date().timeIntervalSince(started)))
        let torsoNorm = result.pose.torsoHeight ?? 0.2   // 正規化座標での体の大きさ（縦方向）
        let smoothed = smooth(samples, bodySize: torsoNorm, window: 0.25, maxJump: 1.0, gap: 0.3)
        let kept = smoothed.filter { $0.time >= p.address && $0.time <= p.finish && $0.head != nil }.count
        var csv = "t,phase,handX,handY,headX,headY,blobX,blobY,estX,estY,length,hits,detX,detY,detConf\n"
        var found = 0, total = 0, blobFound = 0, estimated = 0, detectedCount = 0
        var detectedByEighth = [(Int, Int)](repeating: (0, 0), count: 8)
        for s in samples where s.time >= p.address && s.time <= p.finish {
            total += 1
            if s.head != nil { found += 1 }
            if s.blob != nil { blobFound += 1 }
            if s.estimate != nil { estimated += 1 }
            let eighth = min(Int((s.time - p.address) / (p.finish - p.address) * 8), 7)
            detectedByEighth[eighth].1 += 1
            if s.detected != nil { detectedCount += 1; detectedByEighth[eighth].0 += 1 }
            let phase = s.time < p.top ? "B" : (s.time < p.impact ? "D" : "F")
            csv += String(format: "%.3f,%@,%@,%@,%@,%@,%.2f,%d,%@\n", s.time, phase,
                          s.hand.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? ",",
                          s.head.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? ",",
                          s.blob.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? ",",
                          s.estimate.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? ",", s.length, s.hits,
                          s.detected.map { String(format: "%.3f,%.3f,%.2f", $0.x, $0.y, s.detectedConfidence) } ?? ",,")
        }
        try csv.write(to: outDir.appendingPathComponent("heads.csv"), atomically: true, encoding: .utf8)
        print(String(format: "  スイング区間のフレーム %d 本中、線 %d 本（%.0f%%）、黒い塊 %d 本（%.0f%%）、線からの推定 %d 本（%.0f%%）",
                     total, found, Double(found) / Double(max(total, 1)) * 100, blobFound, Double(blobFound) / Double(max(total, 1)) * 100,
                     estimated, Double(estimated) / Double(max(total, 1)) * 100))
        if detector != nil {
            print(String(format: "  検出器のヘッド %d 本（%.0f%%）。スイングを 8 等分した区間ごと: %@", detectedCount, Double(detectedCount) / Double(max(total, 1)) * 100,
                         detectedByEighth.map { "\($0.0)/\($0.1)" }.joined(separator: " ")))
        }
        print(String(format: "  軌跡モデル：上げのインライア %d 本、下げのインライア %d 本。曲線で決まった位置 %d 本（%.0f%%）",
                     supports.upSupport, supports.downSupport, modelledCount, Double(modelledCount) / Double(max(total, 1)) * 100))
        let times: [(String, Double)] = [
            ("A", p.address), ("B1", p.address + (p.top - p.address) * 0.33), ("B2", p.address + (p.top - p.address) * 0.66), ("T", p.top),
            ("D1", p.top + (p.impact - p.top) * 0.5), ("I", p.impact), ("F1", p.impact + (p.finish - p.impact) * 0.4), ("F", p.finish)]
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
        for (label, t) in times {
            try overlay(url: url, time: t, samples: samples.filter { $0.time >= p.address - 0.3 }, upTo: t,
                        to: outDir.appendingPathComponent(String(format: "%@_%@_%05.2f.png", name, label, t)))
        }
        try overlay(url: url, time: p.impact, samples: samples.filter { $0.time >= p.address && $0.time <= p.finish }, upTo: p.finish,
                    to: outDir.appendingPathComponent("trajectory.png"))
        try overlay(url: url, time: p.impact, samples: smoothed.filter { $0.time >= p.address && $0.time <= p.finish }, upTo: p.finish,
                    to: outDir.appendingPathComponent("trajectory_smoothed.png"))
        // 一覧（4 × 2）
        let files = times.map { outDir.appendingPathComponent(String(format: "%@_%@_%05.2f.png", name, $0.0, $0.1)) }
        let images = files.compactMap { NSImage(contentsOf: $0) }
        if let firstImage = images.first {
            let cw = 320.0, ch = 320.0 * firstImage.size.height / firstImage.size.width
            let sheet = NSImage(size: NSSize(width: cw * 4, height: ch * 2))
            sheet.lockFocus()
            for (k, img) in images.enumerated() {
                let col = k % 4, row = 1 - k / 4
                img.draw(in: NSRect(x: Double(col) * cw, y: Double(row) * ch, width: cw, height: ch))
            }
            sheet.unlockFocus()
            if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: outDir.appendingPathComponent("sheet.png"))
            }
        }
    } catch { print("ERROR \(error)") }
    done.signal()
}
done.wait()
