import Foundation

/// 比較相手と右ペインの位置合わせ。相手自身の表示設定を変えないよう、スイング側が所有する。
struct Pairing: Codable, Equatable {
    var partnerID: UUID
    var transform: PaneTransform = .identity
    /// 「いつものお手本」を選ぶための、相手を決めた日時
    var pairedAt: Date = Date()
}

extension Pairing {
    private enum CodingKeys: String, CodingKey { case partnerID, pairedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partnerID = try c.decode(UUID.self, forKey: .partnerID)
        pairedAt = try c.decodeIfPresent(Date.self, forKey: .pairedAt) ?? Date()
        transform = try PaneTransform(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(partnerID, forKey: .partnerID)
        try c.encode(pairedAt, forKey: .pairedAt)
        // 保存形式の版 2 と同じ階層に位置合わせのキーを書く
        try transform.encode(to: encoder)
    }
}
