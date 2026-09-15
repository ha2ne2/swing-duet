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
    /// ★ を付けた日時（外すと nil）。一覧の ★ の節は**最後に付けたものが一番上**。これより前の保存データには無い。
    /// `isFavorite` と 2 つで 1 つの状態なので、`setFavorite` / `inheritUserEdits` の外で片方だけ動かさない
    var favoritedAt: Date? = nil
    /// お手本の棚（「お手本」タブ）に並べるか。「今回だけ使う」で右に入れた動画は false で、
    /// 相手にしているスイングが無くなれば次回起動時に消える（スイングでは常に true）
    var isRegistered: Bool = true
    /// 動画の情報・解析結果・表示変換。解析が終わるまでは `VideoConfig.placeholder` の値。
    /// `fileName` が空なら動画は写真ライブラリの参照（`source`）
    var video: VideoConfig
    var analysis: AnalysisState = .done
    /// 撮影中のライブ追跡（15fps）から付けた仮のフェーズのままで、止めた後に 30fps で解析し直す必要があるか。
    /// 解析の状態は `done`（すぐ開ける）のまま、解析キューがこの印の付いたものを後から解析し直す（`ClipStore.analyze`）
    var needsReanalysis: Bool = false
    /// 最後に比べた相手と右ペインの位置合わせ（左ペインに入れたクリップが持つ）
    var pairing: Pairing? = nil
    /// 相手への参照を復号できなかった。保存せず、起動時の自動整理を止めるためだけに使う
    var hasUnreadablePairing = false

    /// 同じクリップでも動画の出どころが替われば、プレーヤーとサムネイルを読み直す
    struct VideoIdentity: Hashable {
        let id: UUID
        let source: VideoSource
    }
    var videoIdentity: VideoIdentity { VideoIdentity(id: id, source: source) }

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

    /// 左（自分）に置けるか。スイングの一覧に出るもの。
    /// お手本を左に入れると、一覧に出ない・★ が効かないクリップになってしまうので入れさせない
    var isMine: Bool { role == .swing }

    /// 右（お手本）に置ける種類か。登録済みのお手本と、★ お気に入りのスイング。
    /// **解析はまだでもよい**（右ペインは「解析中」を出して、済んだら自動で比較に入る）
    var canBePartner: Bool { role == .model || isFavorite }

    /// いますぐ右に置いて比べられるか。棚に並べる相手といつものお手本の選定はこちらを見る
    var isReadyAsPartner: Bool { canBePartner && isAnalyzed }

    /// サムネイルに出すコマの時刻。解析が済んでいなければ先頭
    func thumbnailTime(of phase: SwingPhase) -> Double {
        isAnalyzed ? video.phases.time(of: phase) : 0
    }

    /// ★ を付ける・外す（日時も一緒に動かす）。既に同じ状態なら日時を打ち直さない：
    /// まとめて ★ を付けたときに、元から ★ だったものの並びを動かさないため
    mutating func setFavorite(_ on: Bool, at date: Date = Date()) {
        guard isFavorite != on else { return }
        isFavorite = on
        favoritedAt = on ? date : nil
    }

    /// 切り出しや解析し直しの間に付いた手入れ（名前・★・動画の速さ）を引き継ぐ。
    /// ★ は付いているかと付けた日時の 2 つで 1 つなので、まとめてここで写す
    mutating func inheritUserEdits(from source: Clip) {
        name = source.name
        isFavorite = source.isFavorite
        favoritedAt = source.favoritedAt
        video.slowFactor = source.video.slowFactor
    }

    /// このスイングとの比較で使う相手の位置合わせ。相手を替えた直後は自動フィットに戻る
    func partnerTransform(for partnerID: UUID) -> PaneTransform {
        guard let pairing, pairing.partnerID == partnerID else { return .identity }
        return pairing.transform
    }

}

extension Clip {
    /// 長い動画 `take` から切り出した 1 球のクリップ。解析結果は切り出した範囲の分（`sliced`）、相手は元と同じ。
    /// 撮影日時は元の撮影日時に範囲の先頭を足す（焼き込みスローでは動画秒なので目安）。`id` を渡すと元のクリップの id を引き継ぐ
    /// （ステージが元のクリップを開いたままなら、そのまま最後の球を映す）
    static func shot(from take: Clip, range: ClosedRange<Double>, sliced: SwingAnalysisResult, source: VideoSource, id: UUID) -> Clip {
        let stored = source.stored
        return Clip(id: id, role: .swing, createdAt: take.createdAt, shotAt: take.shotAt.map { $0.addingTimeInterval(range.lowerBound) },
                    assetID: stored.assetID, cloudID: stored.cloudID, video: sliced.videoConfig(fileName: stored.fileName), analysis: .done, pairing: take.pairing)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, name, createdAt, shotAt, assetID, cloudID, isFavorite, favoritedAt, isRegistered, video, analysis, needsReanalysis, pairing
    }

    /// 後から追加したキー（isRegistered / cloudID / needsReanalysis / favoritedAt）が無い保存データも読めるようにする
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
        favoritedAt = try c.decodeIfPresent(Date.self, forKey: .favoritedAt)
        isRegistered = try c.decodeIfPresent(Bool.self, forKey: .isRegistered) ?? true
        video = try c.decode(VideoConfig.self, forKey: .video)
        analysis = try c.decode(AnalysisState.self, forKey: .analysis)
        needsReanalysis = try c.decodeIfPresent(Bool.self, forKey: .needsReanalysis) ?? false
        // 相手の情報が読めなくても、クリップ（＝動画への参照）は失わない。相手はいつものお手本に落ちる
        do {
            pairing = try c.decodeIfPresent(Pairing.self, forKey: .pairing)
        } catch {
            pairing = nil
            hasUnreadablePairing = true
        }
    }
}
