import CoreGraphics

/// 長さ `duration`（秒）の時間軸を幅 `width`（pt）に写す。共通タイムライン（シークバー）と
/// 動画の時間軸（フェーズ調整・ライブラリのプレビュー）が同じ計算を使うための入れ物
struct TimeScale {
    let duration: Double
    let width: CGFloat

    /// その時刻の x。軸の外は端で止める
    func x(of time: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * CGFloat((time / duration).clamped(to: 0...1))
    }

    /// その x の時刻。`clamping` が false なら軸の外（負や長さ超え）も返す
    func time(atX x: CGFloat, clamping: Bool = true) -> Double {
        let fraction = Double(x / max(width, 1))
        return (clamping ? fraction.clamped(to: 0...1) : fraction) * duration
    }

    /// 移動量（pt）が表す時間の差
    func time(movedBy dx: CGFloat) -> Double {
        Double(dx / max(width, 1)) * duration
    }
}
