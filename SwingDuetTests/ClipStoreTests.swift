import Testing
import Foundation
@testable import SwingDuet

/// `ClipStore` の純粋な部分（保存形式の版上げ、流す上限、相手の解決、削除と元に戻す、同じ動画の共有）を一時ディレクトリで固定する。
/// 解析キューは回さない（`autoAnalyze: false`）ので、動画ファイルは要らない
@MainActor
struct ClipStoreTests {

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeStore() -> ClipStore {
        ClipStore(documentsURL: directory, autoAnalyze: false)
    }

    private func video(_ fileName: String, impact: Double = 1.0) -> VideoConfig {
        VideoConfig(fileName: fileName, duration: 3, frameRate: 30,
                    phases: PhaseSet(address: 0.2, top: 0.8, impact: impact, finish: 1.5))
    }

    private func write(_ text: String, to name: String) throws {
        try text.data(using: .utf8)?.write(to: directory.appendingPathComponent(name))
    }

    @Test func paneEditsChangeOnlyTheirOwnedValues() throws {
        let store = makeStore()
        let swing = store.add(role: .swing, fileName: "s.mov", shotAt: nil, assetID: nil)
        let partner = store.add(role: .model, fileName: "p.mov", shotAt: nil, assetID: nil)
        let original = video("p.mov")
        store.mutate(partner.id) {
            $0.video = original
            $0.video.candidates = [original.phases]
            $0.video.jointTrails = JointTrails(samples: [])
            $0.video.transform = PaneTransform(scale: 3)
        }
        store.setPartner(of: swing.id, to: partner.id)
        let pairedAt = store.clip(id: swing.id)?.pairing?.pairedAt
        let mine = PaneTransform(scale: 2, offsetX: 8)
        let paired = PaneTransform(scale: 1.5, offsetY: -12)
        store.setTransform(mine, of: swing.id)
        store.setPartnerTransform(paired, of: swing.id, partnerID: partner.id)
        var phases = original.phases
        phases.impact += 0.1
        store.setPhases(phases, slowFactor: 8, of: partner.id)

        let saved = try #require(store.clip(id: partner.id))
        #expect(saved.video.phases == phases && saved.video.slowFactor == 8)
        #expect(saved.video.transform == PaneTransform(scale: 3))
        #expect(saved.video.candidates == [original.phases])
        #expect(saved.video.jointTrails == JointTrails(samples: []))
        #expect(store.clip(id: swing.id)?.video.transform == mine)
        #expect(store.clip(id: swing.id)?.partnerTransform(for: partner.id) == paired)
        #expect(store.clip(id: swing.id)?.pairing?.pairedAt == pairedAt)
        #expect(store.clip(id: swing.id)?.partnerTransform(for: UUID()) == .identity)
        let restored = makeStore()
        #expect(restored.clip(id: partner.id)?.video == saved.video)
        #expect(restored.clip(id: swing.id)?.pairing?.transform == paired)
    }

    // MARK: - 壊れた保存データ

    /// library.json を読めないときに動画を消さない。
    /// 参照が 1 つも無い状態で `Documents/Videos` を片付けると、取り込んだ動画も撮った球も全部消える
    @Test func unreadableLibraryKeepsTheVideosAndIsBackedUp() throws {
        try write("{ これは JSON ではない", to: "library.json")
        let videos = directory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try write("dummy", to: "Videos/a.mov")

        let store = makeStore()

        #expect(store.clips.isEmpty)
        #expect(FileManager.default.fileExists(atPath: videos.appendingPathComponent("a.mov").path))
        let backup = try #require(store.damagedLibraryBackup)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(backup).path))
    }

    /// クリップ 1 本が壊れていても、他のクリップは読める（読み飛ばしたときも動画は消さない）
    @Test func oneBrokenClipDoesNotTakeTheOthersDown() throws {
        let goodID = UUID()
        try write("""
        {"version":2,"clips":[
          {"id":"\(goodID.uuidString)","role":"swing","name":"","createdAt":"2026-09-10T00:00:00Z","isFavorite":false,
           "analysis":{"done":{}},
           "video":{"fileName":"a.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}},
          {"id":"not-a-uuid","role":"swing"}
        ]}
        """, to: "library.json")
        let videos = directory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try write("dummy", to: "Videos/b.mov")

        let store = makeStore()

        #expect(store.clips.count == 1)
        #expect(store.clip(id: goodID) != nil)
        #expect(store.damagedLibraryBackup != nil)
        // 読み飛ばしたクリップが参照していたかもしれないので、動画は片付けない
        #expect(FileManager.default.fileExists(atPath: videos.appendingPathComponent("b.mov").path))
    }

    /// 読み込みの途中でディスクに書かない。
    /// 設定（playback）を入れた時点で保存が走ると、まだ復元していない「分割済みの印」を空のまま書いてしまう
    @Test func loadingDoesNotOverwriteTheFileWithHalfRestoredState() throws {
        // 既定と違う再生の設定（＝読み込み中に didSet が鳴る）と、分割済みの印を持った保存データ
        try write("""
        {"version":2,"clips":[],"splitTakes":["asset/9"],
         "playback":{"syncBasis":"mine","anchor":"top","speed":1}}
        """, to: "library.json")

        #expect(makeStore().isAlreadySplit("asset/9"))
        #expect(makeStore().isAlreadySplit("asset/9"))   // 1 度開いた後もディスクに残っている

        let json = try String(contentsOf: directory.appendingPathComponent("library.json"), encoding: .utf8)
        #expect(json.contains("asset"))
    }

    /// 壊れた保存データは上書きしない（退避したファイルから拾い直せるように）。
    /// 上書きすると次の起動は「読めた」ことになり、そこで後片付けが走って動画が消える
    @Test func aDamagedLibraryIsNotOverwritten() throws {
        let broken = "{ これは JSON ではない"
        try write(broken, to: "library.json")
        let store = makeStore()

        store.add(role: .swing, fileName: "a.mov", shotAt: nil, assetID: nil)

        let onDisk = try String(contentsOf: directory.appendingPathComponent("library.json"), encoding: .utf8)
        #expect(onDisk == broken)
        #expect(store.clips.count == 1)   // 画面では使える（保存されないだけ）
    }

    @Test func aReadFailureIsNotTreatedAsFirstLaunch() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Videos"), withIntermediateDirectories: true)
        try write("only copy", to: "Videos/only.mov")
        let store = makeStore()
        #expect(store.isReadOnly)
        #expect(try String(contentsOf: directory.appendingPathComponent("Videos/only.mov"), encoding: .utf8) == "only copy")
    }

    @Test func missingMetadataWithExistingVideosStaysProtectedAcrossLaunches() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Videos"), withIntermediateDirectories: true)
        try write("only copy", to: "Videos/only.mov")
        let store = makeStore()
        #expect(store.isReadOnly)
        #expect(store.damagedLibraryBackup == nil)
        store.add(role: .swing, fileName: "new.mov", shotAt: nil, assetID: nil)
        #expect(makeStore().isReadOnly)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Videos/only.mov").path))
    }

    @Test func aFutureLibraryIsNeverDowngradedOrCleaned() throws {
        let future = "{\"version\":999,\"clips\":[],\"futureReferences\":[\"only.mov\"]}"
        try write(future, to: "library.json")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Videos"), withIntermediateDirectories: true)
        try write("only copy", to: "Videos/only.mov")
        let store = makeStore()
        store.capture.soundEnabled = false
        #expect(store.isReadOnly)
        #expect(try String(contentsOf: directory.appendingPathComponent("library.json"), encoding: .utf8) == future)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Videos/only.mov").path))
    }

    @Test func invalidPairingPreventsDeletionOfItsUnregisteredPartner() throws {
        let store = makeStore()
        let model = store.add(role: .model, fileName: "model.mov", shotAt: nil, assetID: nil, registered: false)
        store.add(role: .swing, fileName: "swing.mov", shotAt: nil, assetID: nil, partnerID: model.id)
        let url = directory.appendingPathComponent("library.json")
        let data = try Data(contentsOf: url)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var clips = try #require(json["clips"] as? [[String: Any]])
        clips[1]["pairing"] = ["partnerID": "invalid"]
        json["clips"] = clips
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let reopened = makeStore()
        #expect(reopened.isReadOnly)
        #expect(reopened.clip(id: model.id) != nil)
    }

    @Test func duplicateIDsProtectAllVideoReferences() throws {
        let store = makeStore()
        let clip = store.add(role: .swing, fileName: "first.mov", shotAt: nil, assetID: nil)
        var duplicate = clip
        duplicate.video.fileName = "second.mov"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Library(clips: [clip, duplicate])).write(to: directory.appendingPathComponent("library.json"))
        #expect(makeStore().isReadOnly)
    }

    @Test func discardedShotDoesNotDeleteASharedOrUndoableVideo() throws {
        let store = makeStore()
        let shot = store.add(role: .swing, fileName: "shared.mov", shotAt: nil, assetID: nil)
        let twin = store.add(role: .model, fileName: "shared.mov", shotAt: nil, assetID: nil)
        try write("only copy", to: "Videos/shared.mov")
        store.delete([twin.id])
        store.discardCapturedShot(shot.id)
        store.restoreDeleted()
        #expect(store.clip(id: twin.id) != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Videos/shared.mov").path))
    }

    @Test func failedPersistenceKeepsTheDiscardedShotsFile() throws {
        let store = makeStore()
        let shot = store.add(role: .swing, fileName: "only.mov", shotAt: nil, assetID: nil)
        try write("only copy", to: "Videos/only.mov")
        // 容量・権限に依存せず、保存先をディレクトリで塞いで書き込み失敗を再現する
        try FileManager.default.removeItem(at: directory.appendingPathComponent("library.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        store.discardCapturedShot(shot.id)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Videos/only.mov").path))
    }

    @Test func promotionUpdatesTheUndoReferenceAfterDeletionDuringSave() async throws {
        var currentStore: ClipStore?
        var shotID: UUID?
        let store = ClipStore(documentsURL: directory, autoAnalyze: false) { _, _ in
            let id = try #require(shotID)
            currentStore?.delete([id])
            return ("saved-local", "saved-cloud")
        }
        currentStore = store
        let shot = store.add(role: .swing, fileName: "only.mov", shotAt: nil, assetID: nil)
        shotID = shot.id
        try write("only copy", to: "Videos/only.mov")
        await store.promoteCapturedShot(shot.id)
        store.restoreDeleted()
        #expect(store.clip(id: shot.id)?.source == .library(localID: "saved-local", cloudID: "saved-cloud"))
        #expect(makeStore().clip(id: shot.id)?.source == store.clip(id: shot.id)?.source)
        currentStore = nil
    }

    @Test func lastSuccessfulSplitKeepsIdentityAndCurrentEdits() throws {
        let store = makeStore()
        let take = store.add(role: .swing, fileName: "take.mov", shotAt: nil, assetID: "take")
        let model = store.add(role: .model, fileName: "model.mov", shotAt: nil, assetID: nil)
        let shot = Clip(role: .swing, video: video("cut.mov"))
        store.rename(take.id, to: "練習")
        store.setFavorite(take.id, true)
        store.setPartner(of: take.id, to: model.id)
        let favoritedAt = try #require(store.clip(id: take.id)?.favoritedAt)
        store.completeSplit(takeID: take.id, shots: [shot])
        let result = try #require(store.clip(id: take.id))
        #expect(result.fileName == "cut.mov")
        #expect(result.name == "練習" && result.isFavorite)
        // ★ は付けた日時も一緒に引き継ぐ（片方だけだと ★ の節の並びから外れる）
        #expect(result.favoritedAt == favoritedAt)
        #expect(result.pairing?.partnerID == model.id)
        #expect(store.isAlreadySplit("take"))
    }

    // MARK: - 相手（お手本）

    /// 「動画」タブから選んだばかりのお手本は解析中。それでも右ペインに入れられる（済んだら比較に入る）
    @Test func anUnanalyzedModelCanStillBeChosenAsThePartner() {
        let store = makeStore()
        let swing = store.add(role: .swing, fileName: "s.mov", shotAt: nil, assetID: nil)
        let model = store.add(role: .model, fileName: "m.mov", shotAt: nil, assetID: nil)
        #expect(model.analysis == .pending)

        store.setPartner(of: swing.id, to: model.id)

        #expect(store.clip(id: swing.id)?.pairing?.partnerID == model.id)
    }

    /// いま右にいる相手をもう一度選んでも、右ペインの位置合わせは残す
    @Test func choosingTheSamePartnerAgainKeepsThePaneAlignment() {
        let store = makeStore()
        let swing = store.add(role: .swing, fileName: "s.mov", shotAt: nil, assetID: nil)
        let model = store.add(role: .model, fileName: "m.mov", shotAt: nil, assetID: nil)
        store.setPartner(of: swing.id, to: model.id)
        store.mutate(swing.id) { $0.pairing?.transform.scale = 1.5 }

        store.setPartner(of: swing.id, to: model.id)

        #expect(store.clip(id: swing.id)?.pairing?.transform.scale == 1.5)
    }

    /// スイングを相手にできるのは ★ お気に入りだけ（一覧に出ない行を作らない）
    @Test func aPlainSwingCannotBeUsedAsThePartner() {
        let store = makeStore()
        let swing = store.add(role: .swing, fileName: "s.mov", shotAt: nil, assetID: nil)
        let other = store.add(role: .swing, fileName: "o.mov", shotAt: nil, assetID: nil)

        store.setPartner(of: swing.id, to: other.id)
        #expect(store.clip(id: swing.id)?.pairing?.partnerID != other.id)

        store.setFavorite(other.id, true)
        store.setPartner(of: swing.id, to: other.id)
        #expect(store.clip(id: swing.id)?.pairing?.partnerID == other.id)
    }

    // MARK: - 保存形式の版上げ

    @Test func loadingAVersionOneLibraryKeepsOnlyUserChosenSlowFactors() throws {
        let estimatedID = UUID()
        let manualID = UUID()
        let uncertainID = UUID()
        // 版 1 の library.json：推定値（4）のまま・ユーザーが 8 を選んだ・信頼度が低くて 1 のまま（ダウンスイングはどれも動画上 1.2 秒）
        try write("""
        {"version":1,"reference":"model","clips":[
          {"id":"\(estimatedID.uuidString)","role":"model","name":"A","createdAt":"2026-09-10T00:00:00Z","isFavorite":false,"analysis":{"done":{}},
           "video":{"fileName":"a.mov","duration":20,"frameRate":30,"slowFactor":4,"phases":{"address":2,"top":8.4,"impact":9.6,"finish":14}}},
          {"id":"\(manualID.uuidString)","role":"model","name":"B","createdAt":"2026-09-10T00:00:00Z","isFavorite":false,"analysis":{"done":{}},
           "video":{"fileName":"b.mov","duration":20,"frameRate":30,"slowFactor":8,"phases":{"address":2,"top":8.4,"impact":9.6,"finish":14}}},
          {"id":"\(uncertainID.uuidString)","role":"model","name":"C","createdAt":"2026-09-10T00:00:00Z","isFavorite":false,"analysis":{"done":{}},
           "video":{"fileName":"c.mov","duration":20,"frameRate":30,"slowFactor":1,"lowConfidence":true,"phases":{"address":2,"top":8.4,"impact":9.6,"finish":14}}}
        ]}
        """, to: "library.json")

        let store = makeStore()
        #expect(store.clip(id: estimatedID)?.video.slowFactor == nil)          // 推定に従う
        #expect(store.clip(id: estimatedID)?.video.effectiveSlowFactor == 4)
        #expect(store.clip(id: manualID)?.video.slowFactor == 8)               // 選んだ値は残る
        #expect(store.clip(id: uncertainID)?.video.slowFactor == nil)          // 信頼度が低くても、手で置いたフェーズからは推定する
        #expect(store.clip(id: uncertainID)?.video.effectiveSlowFactor == 4)
        #expect(makeStore().clip(id: estimatedID)?.video.slowFactor == nil)    // 版が上がって保存される
    }

    // MARK: - ★ お気に入り

    /// ★ の節は「最後に付けたものが先頭」。付けた日時を持たない古い保存データは後ろに撮影日順で続く
    @Test func favoritesAreOrderedByWhenTheStarWasPut() {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 撮影は old → new の順。★ を付ける順はその逆にする
        let old = store.add(role: .swing, fileName: "old.mov", shotAt: base, assetID: nil)
        let new = store.add(role: .swing, fileName: "new.mov", shotAt: base.addingTimeInterval(60), assetID: nil)
        let legacy = store.add(role: .swing, fileName: "legacy.mov", shotAt: base.addingTimeInterval(120), assetID: nil)
        store.mutate(new.id) {
            $0.isFavorite = true
            $0.favoritedAt = base.addingTimeInterval(1000)
        }
        store.mutate(old.id) {
            $0.isFavorite = true
            $0.favoritedAt = base.addingTimeInterval(2000)
        }
        store.mutate(legacy.id) { $0.isFavorite = true }   // 古い保存データ（日時なし）

        #expect(store.favorites.map(\.id) == [old.id, new.id, legacy.id])
    }

    /// ★ を付けた日時は付けたときだけ打ち直す（まとめて ★ にしても、元から ★ だったものの並びは動かない）
    @Test func puttingTheStarStampsTheDateAndRemovingItClears() throws {
        let store = makeStore()
        let clip = store.add(role: .swing, fileName: "s.mov", shotAt: nil, assetID: nil)
        store.setFavorite(clip.id, true)
        let first = try #require(store.clip(id: clip.id)?.favoritedAt)

        store.setFavorite(clip.id, true)                        // 既に ★ なら日時はそのまま
        #expect(store.clip(id: clip.id)?.favoritedAt == first)

        store.setFavorite(clip.id, false)
        #expect(store.clip(id: clip.id)?.isFavorite == false)
        #expect(store.clip(id: clip.id)?.favoritedAt == nil)    // 外したら日時も消す（付け直せば先頭に来る）
    }

    // MARK: - 追加と上限

    @Test func swingsBeyondTheLimitFlowOutOldestFirstButFavoritesStay() {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [UUID] = []
        // 解析済みのスイングを上限 + 2 本作る。流すのは追加のときで、解析待ちは数えないので、全部足してから解析済みにする
        for i in 0..<(ClipStore.swingLimit + 2) {
            ids.append(store.add(role: .swing, fileName: "s\(i).mov", shotAt: base.addingTimeInterval(Double(i) * 60), assetID: nil).id)
        }
        for id in ids {
            var done = store.clip(id: id)!
            done.analysis = .done
            store.update(done)
        }
        store.setFavorite(ids[0], true)                        // 最も古いものを ★ に
        #expect(store.clips.count == ClipStore.swingLimit + 2)  // 解析済みにしただけでは流れない
        store.add(role: .swing, fileName: "extra.mov", shotAt: base.addingTimeInterval(1e6), assetID: nil)

        #expect(store.clip(id: ids[0]) != nil)                 // ★ は残る
        #expect(store.clip(id: ids[1]) == nil)                 // ★ の無い最も古いものが流れた
        #expect(store.clip(id: ids[2]) != nil)
        #expect(store.swings.filter { !$0.isFavorite && $0.isAnalyzed }.count == ClipStore.swingLimit)
    }

    /// 当日のスイングは上限に数えず、流れない
    @Test func todaysSwingsAreNeitherCountedNorFlowedOut() {
        let store = makeStore()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [UUID] = []
        for i in 0..<ClipStore.swingLimit {
            ids.append(store.add(role: .swing, fileName: "s\(i).mov", shotAt: old.addingTimeInterval(Double(i) * 60), assetID: nil).id)
        }
        for i in 0..<3 {
            ids.append(store.add(role: .swing, fileName: "t\(i).mov", shotAt: Date().addingTimeInterval(Double(-i) * 60), assetID: nil).id)
        }
        for id in ids {
            var done = store.clip(id: id)!
            done.analysis = .done
            store.update(done)
        }
        store.add(role: .swing, fileName: "now.mov", shotAt: Date(), assetID: nil)   // 当日の追加では何も流れない
        #expect(store.swings.count == ClipStore.swingLimit + 4)
        store.add(role: .swing, fileName: "later.mov", shotAt: old.addingTimeInterval(1e6), assetID: nil)
        var later = store.swings.first { $0.fileName == "later.mov" }!
        later.analysis = .done
        store.update(later)
        store.add(role: .swing, fileName: "trigger.mov", shotAt: old.addingTimeInterval(2e6), assetID: nil)
        #expect(store.clip(id: ids[0]) == nil)                  // 過去の最も古いものが流れた
        #expect(ids.suffix(3).allSatisfy { store.clip(id: $0) != nil })   // 当日の分は残る
    }

    // MARK: - 動画の出どころ

    /// ファイル名が空で写真ライブラリの識別子があれば参照。ファイル名があればコピー（旧データも）
    @Test func sourceIsLibraryReferenceOnlyWhenThereIsNoFile() throws {
        let store = makeStore()
        let referenced = store.add(role: .swing, fileName: "", shotAt: nil, assetID: "asset-1", cloudID: "cloud-1")
        #expect(referenced.source == .library(localID: "asset-1", cloudID: "cloud-1"))
        let copied = store.add(role: .swing, fileName: "c.mov", shotAt: nil, assetID: "asset-2")
        #expect(copied.source == .file("c.mov"))

        // 保存して読み直しても同じ。cloudID の無い旧データはコピー
        let reloaded = makeStore()
        #expect(reloaded.clip(id: referenced.id)?.source == .library(localID: "asset-1", cloudID: "cloud-1"))
        #expect(reloaded.clip(id: copied.id)?.source == .file("c.mov"))
        try write("""
        {"version":2,"clips":[{"id":"\(UUID().uuidString)","role":"swing","name":"","createdAt":"2026-09-01T00:00:00Z","assetID":"asset-3",
          "isFavorite":false,"video":{"fileName":"old.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}},
          "analysis":{"done":{}}}]}
        """, to: "library.json")
        #expect(makeStore().swings.first?.source == .file("old.mov"))
    }

    /// 分割済みの長い動画の記録は保存され、無い旧データでも読める
    @Test func splitTakesPersistAndDefaultToEmpty() throws {
        try write("""
        {"version":2,"clips":[],"splitTakes":["take-1"]}
        """, to: "library.json")
        var library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: directory.appendingPathComponent("library.json")))
        #expect(library.splitTakes == ["take-1"])
        try write("""
        {"version":2,"clips":[]}
        """, to: "library.json")
        library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: directory.appendingPathComponent("library.json")))
        #expect(library.splitTakes.isEmpty)
    }

    @Test func addingTheSameLibraryVideoCopiesTheAnalysisAndResetsTheTransform() {
        let store = makeStore()
        let first = store.add(role: .model, name: "A", fileName: "a.mov", shotAt: nil, assetID: "asset-1")
        var analyzed = first
        analyzed.video = video("a.mov", impact: 1.23)
        analyzed.video.transform.scale = 2
        analyzed.analysis = .done
        store.update(analyzed)

        let twin = store.add(role: .swing, fileName: "a.mov", shotAt: nil, assetID: "asset-1")
        #expect(twin.isAnalyzed)
        #expect(twin.video.phases.impact == 1.23)
        #expect(twin.video.transform.scale == 1)
        #expect(store.existingClip(assetID: "asset-1")?.id == first.id)
    }

    @Test func unregisteredModelsAreHiddenFromTheShelfAndRemovedOnceNoSwingUsesThem() {
        let store = makeStore()
        let hidden = store.add(role: .model, fileName: "h.mov", shotAt: nil, assetID: nil, registered: false)
        let shown = store.add(role: .model, name: "A", fileName: "a.mov", shotAt: nil, assetID: nil)
        #expect(store.models.map(\.id) == [shown.id])
        let swing = store.add(role: .swing, fileName: "s.mov", shotAt: nil, assetID: nil, partnerID: hidden.id)
        #expect(makeStore().clip(id: hidden.id) != nil)   // 相手にしているスイングがある間は残る

        store.delete([swing.id])
        #expect(makeStore().clip(id: hidden.id) == nil)   // 次の起動で消える
        #expect(makeStore().clip(id: shown.id) != nil)    // 登録済みは残る
    }

    // MARK: - 相手の解決

    @Test func partnerFallsBackToTheUsualModelAndNeverToItself() {
        let store = makeStore()
        let modelA = store.add(role: .model, name: "A", fileName: "a.mov", shotAt: nil, assetID: nil)
        markDone(modelA, in: store)
        let swing1 = store.add(role: .swing, fileName: "s1.mov", shotAt: nil, assetID: nil, partnerID: modelA.id)
        markDone(swing1, in: store)
        #expect(store.clip(id: swing1.id)?.pairing?.partnerID == modelA.id)

        // 相手を指定しなければ、いつものお手本（最後に比べた相手）
        let swing2 = store.add(role: .swing, fileName: "s2.mov", shotAt: nil, assetID: nil)
        #expect(swing2.pairing?.partnerID == modelA.id)

        // 相手を消すと、別の最後の相手 → 無ければ nil
        store.delete([modelA.id])
        #expect(store.partner(of: store.clip(id: swing1.id)!) == nil)
        let modelB = store.add(role: .model, name: "B", fileName: "b.mov", shotAt: nil, assetID: nil)
        markDone(modelB, in: store)
        store.setPartner(of: swing2.id, to: modelB.id)
        #expect(store.partner(of: store.clip(id: swing1.id)!)?.id == modelB.id)

        // ★ お気に入りを相手にしたスイングがあっても、そのお気に入り自身の相手は自分自身にならない
        store.setFavorite(swing1.id, true)
        let swing3 = store.add(role: .swing, fileName: "s3.mov", shotAt: nil, assetID: nil, partnerID: swing1.id)
        #expect(swing3.pairing?.partnerID == swing1.id)
        #expect(store.partner(of: store.clip(id: swing1.id)!)?.id == modelB.id)
    }

    // MARK: - 削除と元に戻す

    @Test func deletedClipsCanBeRestoredAndTheLibraryIsPersisted() async throws {
        let store = makeStore()
        let a = store.add(role: .swing, fileName: "a.mov", shotAt: nil, assetID: nil)
        let b = store.add(role: .swing, fileName: "b.mov", shotAt: nil, assetID: nil)
        store.delete([a.id, b.id])
        #expect(store.clips.isEmpty)
        #expect(store.lastDeleted.count == 2)

        store.restoreDeleted()
        #expect(store.clips.count == 2)
        #expect(store.lastDeleted.isEmpty)

        store.playback = PlaybackSettings(
            syncBasis: .free, anchor: .top, speed: 1.0,
            loop: LoopRange(start: LoopEdge(phase: .top, frames: -3), end: LoopEdge(phase: .impact, frames: 6)))
        let reopened = makeStore()
        #expect(reopened.clips.count == 2)
        #expect(reopened.playback == store.playback)

        // 設定の保存は続けて変わる分をまとめる（`persistInterval`）ので、直後の変更は少し待ってから書かれる
        store.playback.loop = nil   // ループしない（JSON ではキーごと省かれる）
        try await Task.sleep(for: .milliseconds(400))
        #expect(makeStore().playback.loop == nil)
    }

    /// 撮影の設定は保存して読み直せる。撮影で切り出したショットは `done` のまま解析し直しの印が付き、印の無い旧データも読める
    @Test func captureSettingsAndCapturedShotsArePersisted() throws {
        let store = makeStore()
        store.capture = { var c = CaptureSettings(); c.camera = .front; c.frameRate = 120; c.soundEnabled = false; return c }()
        let pose = PoseTrack(frames: [])
        let provisional = SwingAnalysisResult(duration: 4.4, frameRate: 240, videoAspect: 9.0 / 16.0, pose: pose, candidates: [])
        let temp = directory.appendingPathComponent("cut.mov")
        try Data("mov".utf8).write(to: temp)
        let shot = try store.keepCapturedShot(at: temp, shotAt: Date(), provisional: provisional)
        #expect(shot.isAnalyzed && shot.needsReanalysis)
        guard case .file(let fileName) = shot.source else { Issue.record("アプリ内のファイルになっていない"); return }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Videos/\(fileName)").path))
        #expect(shot.video.frameRate == 240)

        let reopened = makeStore()
        #expect(reopened.capture == store.capture)
        #expect(reopened.capture.effectiveFrameRate == 120)
        #expect(reopened.clip(id: shot.id)?.needsReanalysis == true)

        // 素振りと決まれば「元に戻す」に残さずクリップとファイルが消える
        store.discardCapturedShot(shot.id)
        #expect(store.clip(id: shot.id) == nil && store.lastDeleted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Videos/\(fileName)").path))

        try write("""
        {"version": 2, "clips": [{"id": "\(UUID().uuidString)", "role": "swing", "name": "", "createdAt": "2026-09-12T10:00:00Z",
          "isFavorite": false, "analysis": {"done": {}},
          "video": {"fileName": "old.mov", "duration": 3, "frameRate": 30, "phases": {"address": 0.2, "top": 0.8, "impact": 1.0, "finish": 1.5}}}]}
        """, to: "library.json")
        let old = makeStore()
        #expect(old.clips.count == 1)
        #expect(old.clips[0].needsReanalysis == false)
        #expect(old.capture == CaptureSettings())
    }

    private func markDone(_ clip: Clip, in store: ClipStore) {
        var done = clip
        done.video = video(clip.fileName)
        done.analysis = .done
        store.update(done)
    }
}
