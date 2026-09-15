import Foundation
import AVFoundation
import Combine
import Photos

/// クリップの操作と解析キューを管理し、画面へ現在のライブラリを公開する。
/// ファイルの読み書きは `LibraryFiles` に委ね、動画を消してよいかはここで参照と保存結果から判断する。
@MainActor
final class ClipStore: ObservableObject {
    /// ★ の無いスイングをいくつまで残すか（超えた分は古い順に消える。一覧のフッターにこの数を出す）。
    /// 当日のスイングは数えない（練習場で 1 日に 100 球撮っても、その日の早いショットが流れないように）
    static let swingLimit = 200

    @Published private(set) var clips: [Clip] = [] {
        didSet { indexByID = Dictionary(clips.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last }) }
    }
    /// id から並びの位置を引く索引。一覧は行ごとに相手を引くので線形探索にしない
    private var indexByID: [UUID: Int] = [:]
    /// 比較画面の再生の設定（アプリ全体で 1 つ）
    @Published var playback = PlaybackSettings() {
        didSet { if playback != oldValue, !isLoading { persistThrottled() } }
    }
    /// 撮影の設定（アプリ全体で 1 つ）
    @Published var capture = CaptureSettings() {
        didSet { if capture != oldValue, !isLoading { persist() } }
    }
    /// 撮影中は解析キューを回さない（Vision を撮影の追跡と取り合わないため）。false に戻すと続きから回る
    var analysisPaused = false {
        didSet { if !analysisPaused { processQueue() } }
    }
    /// いま Vision を走らせているクリップ（解析、または軌跡だけの作り直し）。同時に 1 本しか走らせないための鍵でもある。
    /// 一覧とステージは、解析待ちのクリップがこれなら「解析中…」と出す（軌跡の作り直しは解析済みのクリップなので表示に出ない）
    @Published private(set) var analyzingID: UUID?
    /// 軌跡だけを作り直したいクリップ（比較画面が軌跡を出すときに積む。解析と同じ列に並べて 1 本ずつ処理する）
    private var trailQueue: [UUID] = []
    /// 直前に削除したクリップ（「元に戻す」用。次の削除で入れ替わり、再起動で消える）
    @Published private(set) var lastDeleted: [Clip] = []
    /// 保存データを読めず退避したときの、そのファイル名（ホームで知らせる。動画は消していない）
    @Published private(set) var damagedLibraryBackup: String?
    /// 保存データを読めなかった回。退避したファイルを上書きで失わないよう、この回は書き込まない
    @Published private(set) var isReadOnly = false
    /// 1 球ずつに分けて取り込んだ長い動画の識別子（`Library.splitTakes`）
    private var splitTakes: [String] = []
    /// 保存データを読み込んでいる最中（設定の `didSet` で書き出さない）
    private var isLoading = false
    /// 待たせている設定の保存（`persistThrottled`）と、設定を最後に書いた時刻
    private var pendingPersist: Task<Void, Never>?
    private var lastSettingsWriteAt = Date.distantPast
    /// 設定を書く間隔の下限（秒）
    private static let persistInterval = 0.3

    /// 切り出したショットを入れる写真ライブラリのアルバム
    static let albumName = "SwingDuet"

    private let files: LibraryFiles
    /// 解析キューを回すか（単体テストでは回さない）
    private let autoAnalyze: Bool
    /// 写真ライブラリへの保存。非同期完了と削除が重なる場合もテストできるよう、境界だけ差し替えられる
    private let saveVideo: @MainActor (URL, Date?) async throws -> (localID: String, cloudID: String?)

    /// - documentsURL: 保存先（既定は Documents。単体テストでは一時ディレクトリ）
    init(documentsURL: URL? = nil, autoAnalyze: Bool = true,
         saveVideo: @escaping @MainActor (URL, Date?) async throws -> (localID: String, cloudID: String?) = {
             try await PhotoLibrary.saveVideo(at: $0, creationDate: $1, albumName: ClipStore.albumName)
         }) {
        self.files = LibraryFiles(documentsURL: documentsURL ?? .documents)
        self.autoAnalyze = autoAnalyze
        self.saveVideo = saveVideo
        let read = files.load()
        if read.isDamaged {
            // 不完全な参照集合で動画を整理しない。次回起動も保護できるよう元の JSON を上書きしない。
            damagedLibraryBackup = files.backup()
            isReadOnly = true
        }
        if case .loaded(let library) = read { load(library) }
        if case .loaded = read, !read.isDamaged, removeUnreferencedModels() {
            files.removeUnreferencedVideos(referenced: Set(clips.map(\.fileName)))
        }
        processQueue()
    }

    /// 棚に並べないお手本（「今回だけ使う」で入れたもの）は、相手にしているスイングが無くなれば消す。
    /// 戻り値は**保存データがいまのクリップと一致しているか**。起動時の孤児の片付けは、これが true のときだけ行ってよい
    /// （消しただけで保存に失敗した状態で片付けると、参照が残っている動画まで孤児に見える）
    private func removeUnreferencedModels() -> Bool {
        let referenced = Set(clips.compactMap { $0.pairing?.partnerID })
        let before = clips.count
        clips.removeAll { $0.role == .model && !$0.isRegistered && !referenced.contains($0.id) }
        guard clips.count != before else { return true }
        return persist()
    }

    /// 全項目を復元してから版を移行する。途中の設定代入では JSON を保存しない。
    private func load(_ library: Library) {
        isLoading = true
        clips = library.migrated().clips
        playback = library.playback
        capture = library.capture
        splitTakes = library.splitTakes
        isLoading = false
        guard library.version < Library.currentVersion else { return }

        persist()
    }

    // MARK: - 参照

    func clip(id: UUID?) -> Clip? {
        guard let id, let index = indexByID[id] else { return nil }
        return clips[index]
    }

    /// スイング（撮影日時の新しい順）
    var swings: [Clip] {
        clips.filter { $0.role == .swing }.sorted { $0.sortDate > $1.sortDate }
    }

    /// 登録済みのお手本（登録の新しい順。「今回だけ使う」で入れたものは除く）
    var models: [Clip] {
        clips.filter { $0.role == .model && $0.isRegistered }.sorted { $0.createdAt > $1.createdAt }
    }

    /// ★ お気に入り（★ の付いたスイング。お手本の棚にも並ぶ）。
    /// **最後に ★ を付けたものが先頭**。付けた日時を持たない古い保存データは `.distantPast` に落ちて後ろに回り、
    /// その中では撮影日の新しい順になる
    var favorites: [Clip] {
        swings.filter(\.isFavorite)
            .sorted { ($0.favoritedAt ?? .distantPast, $0.sortDate) > ($1.favoritedAt ?? .distantPast, $1.sortDate) }
    }

    /// この写真ライブラリの動画は、1 球ずつに分けて取り込み済みか（もう一度分けない）
    func isAlreadySplit(_ assetID: String) -> Bool {
        splitTakes.contains(assetID)
    }

    /// 同じ写真ライブラリの動画を既に取り込んでいれば、そのクリップ（解析結果を写す元）。
    /// `role` を渡すとその役割のものだけ。解析済みを優先する（未解析の双子に当たると解析をやり直すことになる）
    func existingClip(assetID: String?, role: ClipRole? = nil) -> Clip? {
        guard let assetID else { return nil }
        let same = clips.filter { $0.assetID == assetID && (role == nil || $0.role == role) }
        return same.first(where: \.isAnalyzed) ?? same.first
    }

    /// いつものお手本：最後に比べた相手（まだ存在して右ペインに置けるもの）。`excluding` は自分自身を相手にしないため
    func usualPartner(excluding id: UUID? = nil) -> Clip? {
        let recent = clips.compactMap { clip in clip.pairing.map { (partnerID: $0.partnerID, at: $0.pairedAt) } }
            .sorted { $0.at > $1.at }
        for pairing in recent {
            if let partner = clip(id: pairing.partnerID), partner.id != id, partner.isReadyAsPartner { return partner }
        }
        return nil
    }

    /// クリップの相手：最後に比べた相手 → いつものお手本 → 無し（右ペインが空）の順に解決する
    func partner(of clip: Clip) -> Clip? {
        if let pairing = clip.pairing, let partner = self.clip(id: pairing.partnerID), partner.id != clip.id {
            return partner
        }
        return usualPartner(excluding: clip.id)
    }

    // MARK: - 動画

    /// クリップの動画。アプリ内のコピーはそのファイル、写真ライブラリの参照は原本。
    /// 参照が復元で変わっていれば引き直して保存し直す。写真アプリで消されていれば `VideoError.missingInLibrary`
    /// - networkAccess: iCloud にしか無い動画をダウンロードしてよいか（サムネイルは落とさない）
    func videoAsset(of clip: Clip, networkAccess: Bool = true) async throws -> AVAsset {
        switch clip.source {
        case .file(let fileName):
            return AVURLAsset(url: files.videoURL(for: fileName))
        case .library(let localID, let cloudID):
            guard let found = PhotoLibrary.fetchVideo(localID: localID, cloudID: cloudID) else { throw VideoError.missingInLibrary }
            if found.localID != localID {
                mutate(clip.id) { $0.assetID = found.localID }
            }
            guard let asset = await PhotoLibrary.requestOriginalAsset(found.asset, networkAccess: networkAccess) else {
                throw VideoError.unavailable
            }
            return asset
        }
    }

    /// ライブラリの動画をこの役割で使う。同じ写真ライブラリの動画が同じ役割で既にあればそれを返し（行を増やさない）、
    /// 無ければ参照（識別子）で足す。OS のピッカー経由の一時ファイルはコピーして足す。どちらも `add` で解析待ちに入る。
    /// - registered: お手本を棚に並べるか（「今回だけ使う」なら false）
    func obtain(role: ClipRole, name: String = "", source: LibrarySource, partnerID: UUID? = nil, registered: Bool = true) async throws -> Clip {
        let shotAt = await source.creationDate
        switch source {
        case .asset(let asset):
            if role == .swing, isAlreadySplit(asset.localIdentifier) { throw VideoError.alreadySplit }
            if var existing = existingClip(assetID: asset.localIdentifier, role: role) {
                if registered {   // もう一度「お手本に追加」されたら棚に並べ、名前を入れていれば付け直す（`update` は変化が無ければ何もしない）
                    existing.isRegistered = true
                    if !name.isEmpty { existing.name = name }
                    update(existing)
                }
                return existing
            }
            return add(role: role, name: name, fileName: "", shotAt: shotAt, assetID: asset.localIdentifier,
                       cloudID: PhotoLibrary.cloudIdentifier(of: asset), partnerID: partnerID, registered: registered)
        case .file(let url):
            return add(role: role, name: name, fileName: try files.importVideo(from: url), shotAt: shotAt, assetID: nil,
                       partnerID: partnerID, registered: registered)
        }
    }

    // MARK: - 追加

    /// 撮影中に切り出した 1 球を、本番か素振りかの判定が出る前にアプリ内のファイルとして足す（打った数秒後に一覧に出す）。
    /// フェーズはライブ追跡から付けた仮のもの（`provisional`）で、すぐ開ける状態（`done`）にし、`needsReanalysis` を立てて撮影を止めた後に
    /// 解析キューが 30fps で解析し直す。相手はいつものお手本。判定が出たら `promoteCapturedShot`（本番）か `discardCapturedShot`（素振り）
    func keepCapturedShot(at url: URL, shotAt: Date, provisional: SwingAnalysisResult) throws -> Clip {
        let fileName = try files.importVideo(from: url)
        var clip = Clip(role: .swing, shotAt: shotAt, video: provisional.videoConfig(fileName: fileName), analysis: .done, needsReanalysis: true)
        if let partner = usualPartner() {
            clip.pairing = Pairing(partnerID: partner.id)
        }
        clips.append(clip)
        trimSwings()
        persist()
        return clip
    }

    /// 本番と決まったショットを写真ライブラリ（アルバム）に移して参照にする。移せなければアプリ内のファイルのまま使う
    func promoteCapturedShot(_ id: UUID) async {
        guard let clip = clip(id: id), case .file(let fileName) = clip.source else { return }
        let url = files.videoURL(for: fileName)
        // NOTE: 写真ライブラリへの保存の失敗（権限なし・容量不足など）はファイルのまま残すので握りつぶす
        guard let saved = try? await saveVideo(url, clip.shotAt) else { return }
        // 削除中も「元に戻す」のクリップが参照を持つ。両方を同じ出どころに切り替えてから保存する。
        func promote(_ clip: inout Clip) {
            guard clip.id == id, clip.source == .file(fileName) else { return }
            clip.video.fileName = ""
            clip.assetID = saved.localID
            clip.cloudID = saved.cloudID
        }
        if let index = indexByID[id] { promote(&clips[index]) }
        for index in lastDeleted.indices { promote(&lastDeleted[index]) }
        if persist() { removeVideoIfUnreferenced(fileName) }
    }

    /// 素振りと決まったショットを消す。参照の保存に成功し、共有・取り消し用の参照も無いときだけファイルを片付ける
    func discardCapturedShot(_ id: UUID) {
        guard let clip = clip(id: id) else { return }
        clips.removeAll { $0.id == id }
        if persist(), case .file(let fileName) = clip.source { removeVideoIfUnreferenced(fileName) }
    }

    private func removeVideoIfUnreferenced(_ fileName: String) {
        guard !fileName.isEmpty,
              !clips.contains(where: { $0.fileName == fileName }),
              !lastDeleted.contains(where: { $0.fileName == fileName }) else { return }
        // NOTE: 呼び手は参照の保存成功を確認済み。失敗時は元の動画を残す
        files.removeVideo(fileName)
    }

    /// 撮影で 1 球も切り出せなかったときに、撮った動画をそのまま長い動画として足す（解析待ち。ショットが 2 つ以上あれば `split` が 1 球ずつにする）
    @discardableResult
    func addCapturedTake(source: VideoSource, shotAt: Date) -> Clip {
        let stored = source.stored
        return add(role: .swing, fileName: stored.fileName, shotAt: shotAt, assetID: stored.assetID, cloudID: stored.cloudID)
    }

    /// 切り出した動画ファイルを写真ライブラリ（アルバム `albumName`）に保存して参照にする。保存できなければアプリ内にコピーする。
    /// どちらも一時ファイルは残らない（コピーは移動、保存は消す）。長い動画の分割と撮影の両方から使う
    func persistVideo(at url: URL, shotAt: Date?) async throws -> VideoSource {
        // NOTE: 写真ライブラリへの保存の失敗（権限なし・容量不足など）はコピーに落とすので握りつぶす
        if let saved = try? await saveVideo(url, shotAt) {
            try? FileManager.default.removeItem(at: url)
            return .library(localID: saved.localID, cloudID: saved.cloudID)
        }
        return .file(try files.importVideo(from: url))
    }

    /// 動画をクリップとして追加し、解析待ちにする。`fileName` が空なら写真ライブラリの参照（`assetID` が本体）。
    /// 同じ写真ライブラリの動画を解析済みで持っていれば、その解析結果を写して解析を省く。
    /// - partnerID: スイングの相手（nil ならいつものお手本）
    /// - registered: お手本を棚に並べるか
    @discardableResult
    func add(role: ClipRole, name: String = "", fileName: String, shotAt: Date?, assetID: String?, cloudID: String? = nil,
             partnerID: UUID? = nil, registered: Bool = true) -> Clip {
        var clip = Clip(role: role, name: name, shotAt: shotAt, assetID: assetID, cloudID: cloudID, isRegistered: registered,
                        video: .placeholder(fileName: fileName), analysis: .pending)
        if let twin = existingClip(assetID: assetID), twin.isAnalyzed {
            clip.video = twin.video
            clip.video.fileName = fileName
            clip.video.transform = .identity
            clip.analysis = .done
        }
        if role == .swing, let partner = partnerID.flatMap({ self.clip(id: $0) }) ?? usualPartner() {
            clip.pairing = Pairing(partnerID: partner.id)
        }
        clips.append(clip)
        trimSwings()
        persist()
        processQueue()
        return clip
    }

    /// ★ の無い解析済みのスイングを新しい順に `swingLimit` 本だけ残す（当日のものは数えず、流さない）
    private func trimSwings() {
        let flowing = swings.filter { !$0.isFavorite && $0.isAnalyzed && !Calendar.current.isDateInToday($0.sortDate) }
        guard flowing.count > Self.swingLimit else { return }
        let dropped = Set(flowing.dropFirst(Self.swingLimit).map(\.id))
        clips.removeAll { dropped.contains($0.id) }
    }

    // MARK: - 編集

    /// クリップを書き換える（変わらなければ保存もしない）。**もう無ければ何もしない**：
    /// 解析や切り出しの `await` の間に消されていることがあるので、書き手はいちいち確かめずにここへ渡す
    @discardableResult
    func mutate(_ id: UUID, _ body: (inout Clip) -> Void) -> Bool {
        guard let index = indexByID[id] else { return false }
        var clip = clips[index]
        body(&clip)
        guard clip != clips[index] else { return true }
        clips[index] = clip
        persist()
        return true
    }

    func update(_ clip: Clip) {
        mutate(clip.id) { $0 = clip }
    }

    func rename(_ id: UUID, to name: String) {
        mutate(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setFavorite(_ id: UUID, _ isFavorite: Bool) {
        mutate(id) { $0.setFavorite(isFavorite) }
    }

    /// フェーズ画面の編集だけを最新の解析結果に重ねる。軌跡や候補、位置合わせは触らない。
    func setPhases(_ phases: PhaseSet, slowFactor: Double?, of id: UUID) {
        mutate(id) {
            $0.video.phases = phases
            $0.video.slowFactor = slowFactor
        }
    }

    func setTransform(_ transform: PaneTransform, of id: UUID) {
        mutate(id) { $0.video.transform = transform }
    }

    /// 右ペインの位置合わせは、相手自身ではなく比較を開いたスイングに保存する
    func setPartnerTransform(_ transform: PaneTransform, of id: UUID, partnerID: UUID) {
        guard partnerID != id, clip(id: partnerID) != nil else { return }
        mutate(id) {
            if $0.pairing?.partnerID != partnerID { $0.pairing = Pairing(partnerID: partnerID) }
            $0.pairing?.transform = transform
        }
    }

    /// 相手を替える。右ペインの位置合わせは自動フィットに戻る（相手が違えば位置も違う）。
    /// 右ペインに置けない種類のクリップ（お手本でも ★ でもない）は相手にしない。解析中の相手は受け付ける
    /// （右ペインが「解析中」を出し、済んだら比較に入る）。同じ相手を選び直したときは位置合わせを残す
    func setPartner(of id: UUID, to partnerID: UUID) {
        guard partnerID != id, let partner = clip(id: partnerID), partner.canBePartner else { return }
        guard clip(id: id)?.pairing?.partnerID != partner.id else { return }
        mutate(id) { $0.pairing = Pairing(partnerID: partner.id) }
    }

    /// クリップを消す（動画ファイルは次回起動時に、参照が無ければ消える）。`restoreDeleted` で戻せる
    func delete(_ ids: Set<UUID>) {
        let removed = clips.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        clips.removeAll { ids.contains($0.id) }
        lastDeleted = removed
        persist()
    }

    /// 直前に消したクリップを戻す
    func restoreDeleted() {
        guard !lastDeleted.isEmpty else { return }
        clips.append(contentsOf: lastDeleted)
        lastDeleted = []
        persist()
    }

    func clearDeleted() {
        lastDeleted = []
    }

    /// 解析に失敗したクリップをもう一度解析待ちにする
    func retryAnalysis(_ id: UUID) {
        guard case .failed = clip(id: id)?.analysis else { return }
        mutate(id) { $0.analysis = .pending }
        processQueue()
    }

    // MARK: - 解析キュー

    /// 軌跡（`VideoConfig.jointTrails`）が無い、または古い部位の組で作られた解析済みクリップに、軌跡だけを後から作らせる。
    /// 比較画面が軌跡を出すときに呼ぶ。フェーズや位置合わせには触らない（解析し直すと手直しが消えるため）
    func requestTrails(of id: UUID) {
        guard let clip = clip(id: id), clip.isAnalyzed, clip.video.jointTrails?.isCurrent != true,
              !trailQueue.contains(id) else { return }
        trailQueue.append(id)
        processQueue()
    }

    /// 解析待ちのクリップを取り込み順に 1 本ずつ解析する（Vision を並列に走らせない）。待ちが無ければ、撮影で仮のフェーズのままのものを
    /// 解析し直し、それも無ければ軌跡だけを作り直す
    private func processQueue() {
        guard autoAnalyze, !isReadOnly, !analysisPaused, analyzingID == nil else { return }
        let waiting = clips.filter { $0.analysis == .pending }
        let candidates = waiting.isEmpty ? clips.filter { $0.needsReanalysis && $0.isAnalyzed } : waiting
        if let next = candidates.min(by: { $0.createdAt < $1.createdAt }) {
            analyzingID = next.id
            Task { await analyze(next) }
        } else if let next = trailQueue.first {
            analyzingID = next
            Task { await buildTrails(of: next) }
        }
    }

    /// 人物追跡だけをやり直して軌跡を作り、保存する。
    /// 失敗したときは空の軌跡を入れる：動画が読めないなど繰り返しても直らない失敗が大半で、
    /// 入れておかないと画面を開くたびに Vision を走らせ、「作成中」の表示も消えない
    private func buildTrails(of id: UUID) async {
        defer {
            trailQueue.removeAll { $0 == id }
            analyzingID = nil
            processQueue()
        }
        guard let clip = clip(id: id) else { return }
        let trails: JointTrails
        do {
            let asset = try await videoAsset(of: clip)
            let pose = try await SwingAnalyzer.trackPose(asset: asset)
            let phases = clip.video.phases
            trails = pose.jointTrails(in: JointTrails.sampleRange(chosen: phases, candidates: clip.video.candidates),
                                      swing: phases.address...phases.finish)
        } catch {
            print("軌跡の作成に失敗: \(clip.displayName) \(error.localizedDescription)")
            trails = JointTrails(samples: [])
        }
        // 作っている間に消された・解析し直されたときは書かない
        guard self.clip(id: id)?.video.jointTrails?.isCurrent != true else { return }
        mutate(id) { $0.video.jointTrails = trails }
    }

    private func analyze(_ clip: Clip) async {
        defer {
            analyzingID = nil
            processQueue()
        }
        // コピーは解析より先に音声を落とす（解析が保存する duration を、以後ずっと読む書き換え後のファイルから取るため）。
        // 失敗しても解析は続ける（音声付きのまま再生はでき、実機でカクつきが残るだけ）。参照はファイルを触れないので再生時に落とす
        if case .file(let fileName) = clip.source {
            do {
                _ = try await VideoImporter.stripAudioTrack(at: files.videoURL(for: fileName))
            } catch {
                print("音声トラックの除去に失敗: \(fileName) \(error.localizedDescription)")
            }
        }
        let outcome: Result<SwingAnalysisResult, Error>
        do {
            let asset = try await videoAsset(of: clip)
            let analysis = try await SwingAnalyzer.analyze(asset: asset)
            // 長い動画（ショットが 2 つ以上のスイング）は 1 球ずつに分ける。解析中に消されていなければ。撮影で切り出した 1 球（解析し直し）は分けない
            if clip.role == .swing, !clip.needsReanalysis, analysis.shots.count >= 2, clips.contains(where: { $0.id == clip.id }) {
                await split(clip, result: analysis, asset: asset)
                return
            }
            outcome = .success(analysis)
        } catch {
            outcome = .failure(error)
        }
        // 解析中に消されていれば `mutate` が何もしない
        mutate(clip.id) { target in
            switch (clip.needsReanalysis, outcome) {
            case (false, .success(let analysis)):
                target.video = analysis.videoConfig(fileName: clip.fileName)
                target.analysis = .done
            case (false, .failure(let error)):
                target.analysis = .failed(error.localizedDescription)
            case (true, .success(let analysis)):
                target.video = Self.reanalyzedVideo(current: target.video, analysis: analysis)
                target.needsReanalysis = false
            case (true, .failure):
                target.needsReanalysis = false   // 仮のフェーズのままでも使える
            }
        }
    }

    /// 撮影中の仮のフェーズ（15fps のライブ追跡）を 30fps の解析で置き換えた設定。位置合わせと動画の速さの選択は残す。
    /// 仮のフェーズを手で直していれば（候補のどれとも一致しない）、そのフェーズは残して候補・人物の範囲・長さだけ更新する
    private static func reanalyzedVideo(current: VideoConfig, analysis: SwingAnalysisResult) -> VideoConfig {
        var video = analysis.videoConfig(fileName: current.fileName)
        video.transform = current.transform
        video.slowFactor = current.slowFactor
        if !current.candidates.contains(current.phases) {
            video.phases = current.phases
            video.lowConfidence = current.lowConfidence
        }
        return video
    }

    // MARK: - 長い動画の分割

    /// 長い動画 `take` を 1 球ずつのクリップに分ける（設計は docs/design/260912_1951-in-app-slowmo-capture-and-shot-split.md）。
    /// ショットはパススルーで切り出して写真ライブラリ（アルバム `albumName`）に保存し参照で持つ。保存できなければアプリ内にコピーする。
    /// 解析結果は切り出した範囲の分を写すので解析し直さない。元のクリップは最後のショットに置き換える（id を引き継ぐので、
    /// 開いたままのステージは最後の球を映す）。1 球も切り出せなければ元のクリップを失敗にする
    private func split(_ take: Clip, result: SwingAnalysisResult, asset: AVAsset) async {
        let shots = result.shots
        var clipsOfShots: [Clip] = []
        for shot in shots {
            do {
                let url = try await VideoImporter.exportSegment(of: asset, range: shot.range)
                let source = try await persistVideo(at: url, shotAt: take.shotAt.map { $0.addingTimeInterval(shot.range.lowerBound) })
                clipsOfShots.append(.shot(from: take, range: shot.range, sliced: result.sliced(to: shot.range), source: source,
                                          id: UUID()))
            } catch {
                print("ショットの切り出しに失敗: \(shot.range) \(error.localizedDescription)")
            }
        }
        completeSplit(takeID: take.id, shots: clipsOfShots)
    }

    /// 分割が成功した分をまとめて反映する。非同期処理中の名前・★・相手の変更は、現在のクリップから引き継ぐ
    func completeSplit(takeID: UUID, shots: [Clip]) {
        guard let index = indexByID[takeID] else { return }
        let take = clips[index]
        guard !shots.isEmpty else {
            clips[index].analysis = .failed(VideoError.unreadable.localizedDescription)
            persist()
            return
        }
        var result = shots
        for i in result.indices { result[i].pairing = take.pairing }
        // 最後の切り出しが失敗しても、最後に成功した球が元の ID を引き継いでステージと相手の参照を保つ
        let last = result.count - 1
        result[last].id = takeID
        result[last].inheritUserEdits(from: take)
        clips.remove(at: index)
        clips.append(contentsOf: result)
        if let assetID = take.assetID { splitTakes.append(assetID) }
        trimSwings()
        persist()
    }

    // MARK: - 保存

    /// 再生の設定を書く。ただし `persistInterval` に 1 回まで（続けて変わる分は最後の値を 1 回だけ書く）。
    /// ループ範囲のつまみは指が 1 コマ動くたびに値が変わる一方、library.json は全クリップの軌跡を含んで数 MB になるので、
    /// そのたびに書くとドラッグの間ずっとメインスレッドが数十 ms ずつ止まる
    private func persistThrottled() {
        if Date().timeIntervalSince(lastSettingsWriteAt) >= Self.persistInterval {
            lastSettingsWriteAt = Date()
            persist()
        } else if pendingPersist == nil {
            pendingPersist = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.persistInterval))
                guard let self, !Task.isCancelled else { return }
                pendingPersist = nil
                lastSettingsWriteAt = Date()
                persist()
            }
        }
    }

    /// 待たせている設定の保存を今すぐ書く（アプリが背景に回るとき）。
    /// 間引き（`persistThrottled`）の待ち時間の間に落とされると、その変更だけが消えるため
    func flushPendingWrites() {
        guard pendingPersist != nil else { return }
        pendingPersist?.cancel()
        pendingPersist = nil
        lastSettingsWriteAt = Date()
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        // 読めなかった保存データを上書きしない（退避したファイルから拾い直せるようにしておく）
        guard !isReadOnly else { return false }
        do {
            try files.save(Library(clips: clips, playback: playback, splitTakes: splitTakes, capture: capture))
            return true
        } catch {
            // NOTE: 書き込みの失敗（容量・保護）は次の保存で上書きされるが、符号化の失敗（数値が NaN になったなど）は
            //       直るまで保存がすべて失敗し続ける。握りつぶすと「閉じたら今日の分が消えた」になるので必ず残す
            print("保存に失敗: \(error.localizedDescription)")
            return false
        }
    }
}

extension ClipStore: ShotPipeline.Storing {}
