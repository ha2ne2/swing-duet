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
}

extension Pairing {
    /// 右ペインの位置合わせを `config` から写す
    init(partnerID: UUID, transformOf config: VideoConfig, pairedAt: Date) {
        self.init(partnerID: partnerID, scale: config.scale, offsetX: config.offsetX, offsetY: config.offsetY, pairedAt: pairedAt)
    }
}

/// クリップの動画の出どころ（設計は docs/design/260912_2011-photo-library-reference-storage.md）
enum VideoSource: Equatable {
    /// アプリ内のコピー（Documents/Videos/<fileName>）。権限が無いときの OS ピッカー経由と、参照にする前に取り込んだもの
    case file(String)
    /// 写真ライブラリの動画。`localID` は `PHAsset.localIdentifier`、`cloudID` はバックアップの復元で識別子が変わったときに引き直す `PHCloudIdentifier`
    case library(localID: String, cloudID: String?)
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
    /// 写真ライブラリでの識別子（`PHAsset.localIdentifier`）。動画を参照で持つときの本体で、同じ動画を取り込み直したときに解析結果を共有する鍵。
    /// OS のピッカーから取り込んだ動画には無い
    var assetID: String? = nil
    /// 写真ライブラリの `PHCloudIdentifier`（文字列）。バックアップの復元で `assetID` が変わったときに引き直す。参照のクリップだけが持つ
    var cloudID: String? = nil
    /// ★ お気に入り（スイングだけ。お手本の棚にも「★ お気に入り」として並ぶ）
    var isFavorite: Bool = false
    /// お手本の棚（「お手本」タブ）に並べるか。「今回だけ使う」で右に入れた動画は false で、
    /// 相手にしているスイングが無くなれば次回起動時に消える（スイングでは常に true）
    var isRegistered: Bool = true
    /// 動画の情報・解析結果・表示変換。解析が終わるまでは `VideoConfig.placeholder` の値。
    /// `fileName` が空なら動画は写真ライブラリの参照（`source`）
    var video: VideoConfig
    var analysis: AnalysisState = .done
    /// 最後に比べた相手と右ペインの位置合わせ（左ペインに入れたクリップが持つ）
    var pairing: Pairing? = nil

    var fileName: String { video.fileName }

    /// 動画の出どころ。ファイル名があればアプリ内のコピー、無ければ写真ライブラリの参照
    var source: VideoSource {
        if video.fileName.isEmpty, let assetID { return .library(localID: assetID, cloudID: cloudID) }
        return .file(video.fileName)
    }

    /// 一覧の並びに使う日時（撮影日時が無ければ取り込み日時）
    var sortDate: Date { shotAt ?? createdAt }

    /// 表示する題。名前が無ければ日時（「9/10 14:32」）
    var displayName: String { name.isEmpty ? sortDate.compactLabel : name }

    /// 表示名に倍率を添えたもの（「マキロイ · 1/8」。焼き込みスローでなければ表示名だけ）。ペインの「替える」の VoiceOver の値に使う
    var paneTitle: String {
        let factor = video.effectiveSlowFactor
        return factor == 1 ? displayName : "\(displayName) · \(SlowFactor.label(factor))"
    }

    var isAnalyzed: Bool { analysis == .done }

    /// サムネイルに出すコマの時刻。解析が済んでいなければ先頭
    func thumbnailTime(of phase: SwingPhase) -> Double {
        isAnalyzed ? video.phases.time(of: phase) : 0
    }

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

extension Clip {
    /// 長い動画 `take` から切り出した 1 球のクリップ。解析結果は切り出した範囲の分（`sliced`）、相手は元と同じ。
    /// 撮影日時は元の撮影日時に範囲の先頭を足す（焼き込みスローでは動画秒なので目安）。`id` を渡すと元のクリップの id を引き継ぐ
    /// （ステージが元のクリップを開いたままなら、そのまま最後の球を映す）
    static func shot(from take: Clip, range: ClosedRange<Double>, sliced: SwingAnalysisResult, source: VideoSource, id: UUID = UUID()) -> Clip {
        let (fileName, assetID, cloudID): (String, String?, String?) = switch source {
        case .file(let fileName): (fileName, nil, nil)
        case .library(let localID, let cloudID): ("", localID, cloudID)
        }
        return Clip(id: id, role: .swing, createdAt: take.createdAt, shotAt: take.shotAt.map { $0.addingTimeInterval(range.lowerBound) },
                    assetID: assetID, cloudID: cloudID, video: sliced.videoConfig(fileName: fileName), analysis: .done, pairing: take.pairing)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, name, createdAt, shotAt, assetID, cloudID, isFavorite, isRegistered, video, analysis, pairing
    }

    /// 後から追加したキー（isRegistered / cloudID）が無い保存データも読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(ClipRole.self, forKey: .role)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        shotAt = try c.decodeIfPresent(Date.self, forKey: .shotAt)
        assetID = try c.decodeIfPresent(String.self, forKey: .assetID)
        cloudID = try c.decodeIfPresent(String.self, forKey: .cloudID)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        isRegistered = try c.decodeIfPresent(Bool.self, forKey: .isRegistered) ?? true
        video = try c.decode(VideoConfig.self, forKey: .video)
        analysis = try c.decode(AnalysisState.self, forKey: .analysis)
        pairing = try c.decodeIfPresent(Pairing.self, forKey: .pairing)
    }
}

/// 保存する全体（Documents/library.json）
struct Library: Codable {
    /// 保存形式の版。読み込んだものがこれより古ければ `ClipStore` が組み替える（2: 動画の速さをユーザーの選択だけ保存する）
    static let currentVersion = 2

    var version: Int = Library.currentVersion
    var clips: [Clip] = []
    /// 比較画面の再生の設定（アプリ全体で 1 つ）
    var playback = PlaybackSettings()
    /// 1 球ずつに分けて取り込んだ長い動画（写真ライブラリの識別子）。同じ動画をもう一度選んだときに二重に分けない
    var splitTakes: [String] = []
}

extension Library {
    private enum CodingKeys: String, CodingKey {
        case version, clips, playback, splitTakes
    }

    /// `version` を書く前のデータ（版 0）と、`playback` / `splitTakes` の無いデータも読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        clips = try c.decode([Clip].self, forKey: .clips)
        playback = try c.decodeIfPresent(PlaybackSettings.self, forKey: .playback) ?? PlaybackSettings()
        splitTakes = try c.decodeIfPresent([String].self, forKey: .splitTakes) ?? []
    }
}
