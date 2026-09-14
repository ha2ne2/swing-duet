import Foundation

/// 比較画面の再生の設定。アプリ全体で 1 つを `Library` に保存し、一覧から開き直しても同じ設定から始める。
/// 持ち主は `PlaybackController`（`settings`）で、変わるたびに `ComparisonView` が `ClipStore` へ書く。再生位置は保存しない
struct PlaybackSettings: Codable, Equatable {
    /// 同期のとり方
    var syncBasis: SyncBasis = .model
    /// 同期しないときに揃えるフェーズ
    var anchor: SwingPhase = .impact
    /// 再生速度（実速に対する倍率。`PlaybackController.speedPresets` のどれか。古い値は読み込み時に一番近いプリセットへ寄る）
    var speed: Double = 0.25
    /// ループ範囲。nil ならループしない（JSON ではキーごと省かれる）
    var loop: LoopRange? = .all
}

extension PlaybackSettings {
    private enum CodingKeys: String, CodingKey {
        case syncBasis, anchor, speed, loop
    }

    /// 後から足したキーが無い保存データも読めるようにする。
    /// NOTE: ここで例外を投げると `Library` 全体が読めなくなり、クリップが全部消える（再生の設定 1 つのために失うものが大きすぎる）。
    ///       `loop` のキーが無いのは「ループしない」を保存した状態なので、既定の `.all` に戻さず nil のままにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PlaybackSettings()
        syncBasis = (try? c.decodeIfPresent(SyncBasis.self, forKey: .syncBasis)) ?? fallback.syncBasis
        anchor = (try? c.decodeIfPresent(SwingPhase.self, forKey: .anchor)) ?? fallback.anchor
        speed = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? fallback.speed
        loop = try? c.decodeIfPresent(LoopRange.self, forKey: .loop)
    }
}
