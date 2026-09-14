import Testing
import Foundation
import CoreGraphics
@testable import SwingDuet

/// 保存データ（Documents/library.json）の読み書きを固定する。
///
/// `Clip` / `VideoConfig` / `Library` / `CaptureSettings` / `JointTrails` は「後から足したキーが無い保存データも読める」ように
/// `init(from:)` を手書きしている。手書きなので**プロパティを足して書き忘れると、その値が静かに読み込まれなくなる**。
/// 往復（符号化 → 復号）で元に戻ることを見ておけば、書き忘れはここで落ちる
struct PersistenceTests {

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: try encoder.encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private var phases: PhaseSet { PhaseSet(address: 0.2, top: 0.8, impact: 1.0, finish: 1.5) }

    /// 値の入ったクリップ（全プロパティが既定値でない）
    private var filledClip: Clip {
        var clip = Clip(
            id: UUID(), role: .model, name: "マキロイ", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            shotAt: Date(timeIntervalSince1970: 1_699_000_000), assetID: "asset/1", cloudID: "cloud/1",
            isFavorite: true, isRegistered: false,
            video: filledVideo, analysis: .failed("読めません"), needsReanalysis: true,
            pairing: Pairing(partnerID: UUID(), transform: PaneTransform(scale: 1.5, offsetX: 12, offsetY: -30),
                             pairedAt: Date(timeIntervalSince1970: 1_698_000_000)))
        clip.name = "マキロイ"
        return clip
    }

    private var filledVideo: VideoConfig {
        VideoConfig(
            fileName: "a.mov", duration: 12.5, frameRate: 240, slowFactor: 8, videoAspect: 0.5625,
            focusRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), transform: PaneTransform(scale: 1.5, offsetX: 12, offsetY: -30),
            phases: phases, lowConfidence: true, candidates: [phases],
            jointTrails: JointTrails(samples: [JointTrailSample(time: 0.5, hands: CGPoint(x: 0.4, y: 0.3),
                                                                head: CGPoint(x: 0.5, y: 0.8))]))
    }

    // MARK: - 往復

    @Test func videoConfigKeepsEveryFieldThroughARoundTrip() throws {
        #expect(try roundTrip(filledVideo) == filledVideo)
    }

    @Test func clipKeepsEveryFieldThroughARoundTrip() throws {
        let clip = filledClip   // 呼ぶたびに UUID が変わるので 1 つに固定する
        #expect(try roundTrip(clip) == clip)
    }

    /// `CaptureSettings` は手書きの `init(from:)` があるためメンバーワイズ init が無い（既定値から差し替えて作る）
    private var filledCapture: CaptureSettings {
        var settings = CaptureSettings()
        settings.camera = .front
        settings.frameRate = 120
        settings.soundEnabled = false
        settings.keepsFullTake = false
        return settings
    }

    @Test func captureSettingsKeepEveryFieldThroughARoundTrip() throws {
        #expect(try roundTrip(filledCapture) == filledCapture)
    }

    @Test func playbackSettingsKeepEveryFieldThroughARoundTrip() throws {
        let settings = PlaybackSettings(
            syncBasis: .free, anchor: .top, speed: 0.125,
            loop: LoopRange(start: LoopEdge(phase: .top, frames: -3), end: LoopEdge(phase: .impact, frames: 6)))
        #expect(try roundTrip(settings) == settings)
        var noLoop = settings
        noLoop.loop = nil
        #expect(try roundTrip(noLoop).loop == nil)   // 「ループしない」はキーごと省かれるので、既定の全体に戻らないこと
    }

    @Test func libraryKeepsEveryFieldThroughARoundTrip() throws {
        let library = Library(clips: [filledClip], playback: PlaybackSettings(syncBasis: .mine, anchor: .address, speed: 0.5, loop: nil),
                              splitTakes: ["asset/9"], capture: filledCapture)
        let decoded = try roundTrip(library)
        #expect(decoded.version == Library.currentVersion)
        #expect(decoded.clips == library.clips)
        #expect(decoded.playback == library.playback)
        #expect(decoded.splitTakes == library.splitTakes)
        #expect(decoded.capture == library.capture)
    }

    @Test func transformsKeepTheFlatStorageKeys() throws {
        let data = try JSONEncoder().encode(filledClip)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["video", "pairing"] {
            let object = try #require(json[field] as? [String: Any])
            #expect(object["transform"] == nil)
            #expect(object["scale"] as? Double == 1.5)
            #expect(object["offsetX"] as? Double == 12)
            #expect(object["offsetY"] as? Double == -30)
        }
        let legacy = #"{"partnerID":"00000000-0000-0000-0000-000000000001","scale":2,"offsetX":7,"offsetY":-4}"#
        let pairing = try decode(Pairing.self, legacy)
        #expect(pairing.transform == PaneTransform(scale: 2, offsetX: 7, offsetY: -4))
    }

    // MARK: - 古い保存データ

    @Test func keysAddedLaterFallBackToTheirDefaults() throws {
        let clip = try decode(Clip.self, """
        {"id":"\(UUID().uuidString)","role":"swing","name":"","createdAt":"2026-09-10T00:00:00Z","isFavorite":false,
         "analysis":{"done":{}},
         "video":{"fileName":"a.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}}
        """)
        #expect(clip.isRegistered)            // 棚に並べる（後から足したキー。既定は表示）
        #expect(!clip.needsReanalysis)
        #expect(clip.cloudID == nil)
        #expect(clip.video.transform.scale == 1 && clip.video.candidates.isEmpty && clip.video.jointTrails == nil)
        #expect(clip.video.slowFactor == nil)
    }

    /// 再生の設定が読めなくても、クリップ（＝動画への参照）は失わない
    @Test func brokenSettingsDoNotTakeTheClipsDownWithThem() throws {
        let library = try decode(Library.self, """
        {"version":2,"clips":[
          {"id":"\(UUID().uuidString)","role":"swing","name":"","createdAt":"2026-09-10T00:00:00Z","isFavorite":false,
           "analysis":{"done":{}},
           "video":{"fileName":"a.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}}],
         "playback":{"speed":"はやい"},
         "capture":{"frameRate":"240"}}
        """)
        #expect(library.clips.count == 1)
        #expect(library.playback.speed == PlaybackSettings().speed)   // 読めない値は既定に戻る
        #expect(library.playback.syncBasis == PlaybackSettings().syncBasis)
        #expect(library.playback.loop == nil)                         // キーが無い = ループしない
        #expect(library.capture == CaptureSettings())
    }

    /// 再生の設定はキーが 1 つ欠けても既定値で読める（欠けて例外になると `Library` ごと読めなくなる）
    @Test func playbackSettingsReadWithMissingKeys() throws {
        let settings = try decode(PlaybackSettings.self, #"{"syncBasis":"mine"}"#)
        #expect(settings.syncBasis == .mine)
        #expect(settings.anchor == PlaybackSettings().anchor)
        #expect(settings.speed == PlaybackSettings().speed)
        #expect(settings.loop == nil)   // キーが無い = ループしない（保存した状態）
    }
}
