import Foundation

/// クリップの役割。スイング（左ペインに入れる自分の動画）か、お手本（右ペインに入れる動画）
enum ClipRole: String, Codable {
    case swing
    case model
}

/// クリップの解析の状態。実行中かどうかは保存せず `ClipStore.analyzingID` で持つ（途中で終了しても次回起動時に待ちから再開する）
enum AnalysisState: Codable, Equatable {
    /// 解析待ち（実行中を含む）
    case pending
    case done
    /// 失敗した理由（画面に出す）
    case failed(String)
}

/// スイングが最後に比べた相手と、そのときの右ペインの位置合わせ（相手が違えば位置も違うのでスイング側が持つ）
struct Pairing: Codable, Equatable {
    var partnerID: UUID
    var scale: Double = 1.0
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// 相手を決めた日時。「いつものお手本」（最後に比べた相手）を決めるのに使う
    var pairedAt: Date = Date()

    /// 右ペインの位置合わせを `config` から写す
    init(partnerID: UUID, transformOf config: VideoConfig, pairedAt: Date) {
        self.init(partnerID: partnerID, scale: config.scale, offsetX: config.offsetX, offsetY: config.offsetY, pairedAt: pairedAt)
    }

    init(partnerID: UUID, scale: Double = 1.0, offsetX: Double = 0, offsetY: Double = 0, pairedAt: Date = Date()) {
        self.partnerID = partnerID
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.pairedAt = pairedAt
    }
}

/// 取り込んだ動画 1 本。スイング（左ペイン）もお手本（右ペイン）も同じ型で、役割で分ける
struct Clip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var role: ClipRole
    /// 名前。空なら日時を表示する
    var name: String = ""
    /// 取り込み日時
    var createdAt: Date = Date()
    /// 撮影日時（写真ライブラリのメタデータ）。一覧の並びと日付の節に使う
    var shotAt: Date? = nil
    /// 写真ライブラリでの識別子（`PHAsset.localIdentifier`）。同じ動画を取り込み直したときにファイルと解析結果を共有するために持つ。
    /// OS のピッカーから取り込んだ動画には無い
    var assetID: String? = nil
    /// ★ ベスト（スイングだけ。お手本の棚にも「★ ベスト」として並ぶ）
    var isFavorite: Bool = false
    /// 動画の情報・解析結果・表示変換。解析が終わるまでは `VideoConfig.placeholder` の値
    var video: VideoConfig
    var analysis: AnalysisState = .done
    /// 最後に比べた相手と右ペインの位置合わせ（左ペインに入れたクリップが持つ）
    var pairing: Pairing? = nil

    var fileName: String { video.fileName }

    /// 一覧の並びに使う日時（撮影日時が無ければ取り込み日時）
    var sortDate: Date { shotAt ?? createdAt }

    /// 表示する題。名前が無ければ日時（「9/10 14:32」）
    var displayName: String { name.isEmpty ? sortDate.compactLabel : name }

    /// ペイン上端に出す題。焼き込みスローなら倍率も（「マキロイ · 1/8」）
    var paneTitle: String {
        let factor = video.effectiveSlowFactor
        return factor == 1 ? displayName : "\(displayName) · \(SlowFactor.label(factor))"
    }

    var isAnalyzed: Bool { analysis == .done }

    /// 右ペインに出す相手の設定：相手の解析結果に、このクリップとの位置合わせ（`pairing`）を重ねたもの。
    /// 相手が `pairing` と違えば自動フィットどおり（位置は相手ごとに違う）
    func pairedConfig(of partner: Clip) -> VideoConfig {
        var config = partner.video
        let transform = pairing?.partnerID == partner.id ? pairing : nil
        config.scale = transform?.scale ?? 1
        config.offsetX = transform?.offsetX ?? 0
        config.offsetY = transform?.offsetY ?? 0
        return config
    }
}

/// 保存する全体（Documents/library.json）
struct Library: Codable {
    /// 保存形式の版。読み込んだものがこれより古ければ `ClipStore` が組み替える（2: 動画の速さをユーザーの選択だけ保存する）
    static let currentVersion = 2

    var version: Int = Library.currentVersion
    var clips: [Clip] = []
    /// 同期の基準側（アプリ全体で 1 つ）
    var reference: VideoSide = .model
}

extension Library {
    private enum CodingKeys: String, CodingKey {
        case version, clips, reference
    }

    /// `version` を書く前のデータ（版 0）も読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        clips = try c.decode([Clip].self, forKey: .clips)
        reference = try c.decode(VideoSide.self, forKey: .reference)
    }
}
