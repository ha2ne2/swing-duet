import Foundation

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
    /// 撮影の設定（カメラ・フレームレート・音。アプリ全体で 1 つ）
    var capture = CaptureSettings()
    /// 読み込みのときに解けずに読み飛ばしたクリップがあった（保存はしない。`ClipStore` が動画の後片付けを止める目印）
    var hasUnreadableClips = false
}

extension Library {
    private enum CodingKeys: String, CodingKey {
        case version, clips, playback, splitTakes, capture
    }

    /// 1 本が壊れていても他のクリップを失わないための入れ物（この `init` は必ず成功する）
    private struct ClipBox: Decodable {
        let clip: Clip?

        init(from decoder: Decoder) throws {
            clip = try? Clip(from: decoder)
        }
    }

    /// `version` を書く前のデータ（版 0）と、`playback` / `splitTakes` / `capture` の無いデータも読めるようにする。
    /// 設定の類は読めなければ既定値で続け、クリップは 1 本ずつ読む（クリップは動画への参照そのものなので、
    /// 1 本の綻びで全部を失わない）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        let boxes = try c.decode([ClipBox].self, forKey: .clips)
        clips = boxes.compactMap(\.clip)
        hasUnreadableClips = clips.count != boxes.count || Set(clips.map(\.id)).count != clips.count
            || clips.contains(where: \.hasUnreadablePairing)
        // 同じ ID を画面へ重ねて渡さない。元の全参照は保護状態でファイルに残す
        var seen = Set<UUID>()
        clips = clips.filter { seen.insert($0.id).inserted }
        playback = (try? c.decodeIfPresent(PlaybackSettings.self, forKey: .playback)) ?? PlaybackSettings()
        splitTakes = (try? c.decodeIfPresent([String].self, forKey: .splitTakes)) ?? []
        capture = (try? c.decodeIfPresent(CaptureSettings.self, forKey: .capture)) ?? CaptureSettings()
    }
}

extension Library {
    /// 古い版の推定倍率を手動指定と区別し、現在の意味に揃える
    func migrated() -> Library {
        guard version < Self.currentVersion else { return self }
        var result = self
        result.version = Self.currentVersion
        if version < 2 {
            // 版 2: 動画の速さはユーザーの選択だけを保存し、無ければ推定に従う。
            // 版 1 は推定値（信頼度が低ければ 1）を全クリップに書いていたので、その値のままのものは選択ではないとみなして消す
            for i in result.clips.indices {
                let video = result.clips[i].video
                if video.slowFactor == (video.lowConfidence ? 1 : video.estimatedSlowFactor) {
                    result.clips[i].video.slowFactor = nil
                }
            }
        }
        return result
    }
}
