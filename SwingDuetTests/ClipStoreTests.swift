import Testing
import Foundation
@testable import SwingDuet

/// `ClipStore` の純粋な部分（旧データの移行、流す上限、相手の解決、削除と元に戻す、同じ動画の共有）を一時ディレクトリで固定する。
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

    private func write(_ json: String, to name: String) throws {
        try json.data(using: .utf8)?.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 旧データの移行

    @Test func legacyProjectsAndModelsBecomeClipsWithPairings() throws {
        let modelID = UUID()
        let olderID = UUID()
        let newerID = UUID()
        try write("""
        [{"id":"\(modelID.uuidString)","name":"マキロイ","createdAt":"2026-09-01T00:00:00Z",
          "config":{"fileName":"m.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}}]
        """, to: "models.json")
        // 新しい順に保存されている：newer（紐付き無し・別の動画）、older（modelID で紐付き・位置合わせあり）
        try write("""
        [{"id":"\(newerID.uuidString)","name":"比較 9/10 02:20","createdAt":"2026-09-10T02:20:00Z","reference":"mine",
          "mine":{"fileName":"s2.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}},
          "model":{"fileName":"x.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}},
         {"id":"\(olderID.uuidString)","name":"比較 9/8 18:40","createdAt":"2026-09-08T18:40:00Z","reference":"model","modelID":"\(modelID.uuidString)",
          "mine":{"fileName":"s1.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}},
          "model":{"fileName":"m.mov","duration":3,"frameRate":30,"scale":1.5,"offsetX":12,"offsetY":-30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}}]
        """, to: "projects.json")

        let store = makeStore()

        #expect(store.models.count == 2)                       // 登録済み + 紐付きの無かった右ペインから作ったお手本
        #expect(store.swings.count == 2)
        let older = try #require(store.clip(id: olderID))
        #expect(older.role == .swing)
        #expect(older.name.isEmpty)                            // 自動命名は引き継がない（日時で表示する）
        #expect(older.pairing?.partnerID == modelID)
        #expect(older.pairing?.scale == 1.5)
        #expect(older.pairing?.offsetX == 12)
        let newer = try #require(store.clip(id: newerID))
        let created = try #require(store.clip(id: newer.pairing?.partnerID))
        #expect(created.role == .model)
        #expect(created.fileName == "x.mov")
        #expect(created.video.scale == 1)                      // お手本自身の位置合わせは初期値に戻す
        #expect(store.playback.syncBasis == .mine)             // 最新の比較の基準
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("projects.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("models.json").path))
    }

    @Test func legacyProjectWithoutLinkReusesModelOfSameFile() throws {
        let modelID = UUID()
        try write("""
        [{"id":"\(modelID.uuidString)","name":"マキロイ","createdAt":"2026-09-01T00:00:00Z",
          "config":{"fileName":"m.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}}]
        """, to: "models.json")
        try write("""
        [{"id":"\(UUID().uuidString)","name":"比較","createdAt":"2026-09-08T18:40:00Z",
          "mine":{"fileName":"s1.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}},
          "model":{"fileName":"m.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}}]
        """, to: "projects.json")

        let store = makeStore()
        #expect(store.models.count == 1)
        #expect(store.swings.first?.pairing?.partnerID == modelID)
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

    @Test func addingTheSameLibraryVideoCopiesTheAnalysisAndResetsTheTransform() {
        let store = makeStore()
        let first = store.add(role: .model, name: "A", fileName: "a.mov", shotAt: nil, assetID: "asset-1")
        var analyzed = first
        analyzed.video = video("a.mov", impact: 1.23)
        analyzed.video.scale = 2
        analyzed.analysis = .done
        store.update(analyzed)

        let twin = store.add(role: .swing, fileName: "a.mov", shotAt: nil, assetID: "asset-1")
        #expect(twin.isAnalyzed)
        #expect(twin.video.phases.impact == 1.23)
        #expect(twin.video.scale == 1)
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

    @Test func deletedClipsCanBeRestoredAndTheLibraryIsPersisted() {
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

        store.playback.loop = nil   // ループしない（JSON ではキーごと省かれる）
        #expect(makeStore().playback.loop == nil)
    }

    private func markDone(_ clip: Clip, in store: ClipStore) {
        var done = clip
        done.video = video(clip.fileName)
        done.analysis = .done
        store.update(done)
    }
}
