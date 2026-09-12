import Foundation

/// 比較画面の再生の設定。アプリ全体で 1 つを `Library` に保存し、一覧から開き直しても同じ設定から始める。
/// 持ち主は `PlaybackController`（`settings`）で、変わるたびに `ComparisonView` が `ClipStore` へ書く。再生位置は保存しない
struct PlaybackSettings: Codable, Equatable {
    /// 同期のとり方
    var syncBasis: SyncBasis = .model
    /// 同期しないときに揃えるフェーズ
    var anchor: SwingPhase = .impact
    /// 再生速度（実速に対する倍率。`PlaybackController.speedPresets` のどれか）
    var speed: Double = 0.3
    /// ループ範囲。nil ならループしない（JSON ではキーごと省かれる）
    var loop: LoopRange? = .all
}
