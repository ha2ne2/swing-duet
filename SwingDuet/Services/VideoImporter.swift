import Foundation
import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI   // NOTE: PhotosPickerItem は PhotosUI の SwiftUI 向け API なので、SwiftUI も import しないと見えない
import UniformTypeIdentifiers

/// PhotosPicker から動画ファイルを受け取るための Transferable。
/// 渡される一時ファイルはクロージャを抜けると消えるので、その場でアプリの一時ディレクトリへコピーする。
/// 写真アプリのスローモーション動画は 30fps のレンダリング版で渡される。原本が要るときは PhotoLibrary（権限あり）から取り込む
private struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return ImportedMovie(url: dest)
        }
    }
}

extension PhotosPickerItem {
    /// 選んだ項目を動画の一時ファイルとして取り出す（あとで `ClipStore.importVideo` でアプリ管理領域へ移す）
    func loadMovieURL() async throws -> URL {
        guard let movie = try await loadTransferable(type: ImportedMovie.self) else {
            throw VideoError.unreadable
        }
        return movie.url
    }
}

/// 取り込んだ動画ファイルの後処理
enum VideoImporter {

    /// 動画ファイルの撮影日時（メタデータ）。無ければ nil。
    /// 写真ライブラリから取り込んだ動画は `PHAsset.creationDate` を使うので、ここを使うのは OS のピッカー経由のとき
    static func creationDate(of url: URL) async -> Date? {
        guard let item = try? await AVURLAsset(url: url).load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// 動画ファイルを映像トラックだけに書き換える（音声が無ければ何もしない）。書き換えたかどうかを返す。
    ///
    /// 再生は常にミュートだが、音声トラックがあるだけで `AVPlayerItem` は再生開始・シークのたびに音声レンダラの起動を待ち、
    /// `currentTime` が 100〜200ms 止まる。比較画面のドリフト補正がそれをシークで直そうとして連鎖し、実機でカクつく
    /// （docs/research/260907_0254-model-video-stutter-on-device.md）。取り込み時に落としておけば、再生・フェーズ調整・
    /// サムネイル・解析のすべてが音声なしのファイルを読む。パススルー書き出しなので再エンコードは無く、数十 ms で終わる
    static func stripAudioTrack(at url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return false }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.noVideoTrack
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.unreadable
        }
        let (timeRange, transform) = try await video.load(.timeRange, .preferredTransform)
        try track.insertTimeRange(timeRange, of: video, at: .zero)
        track.preferredTransform = transform

        // 拡張子に合ったコンテナで書き出す（.mp4 の中身が QuickTime になるのを避ける）
        let fileType: AVFileType = ["mp4", "m4v"].contains(url.pathExtension.lowercased()) ? .mp4 : .mov
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(fileType) else {
            throw VideoError.unreadable
        }
        // 一時ファイルへ書き出してから差し替える。差し替えは原子的で、途中で失敗しても元のファイルは残る
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        session.outputURL = output
        session.outputFileType = fileType
        // NOTE: `export()` は iOS 18 で `export(to:as:)` に置き換わった。最低 OS を 18 以上にしたら移行する
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw session.error ?? VideoError.unreadable
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
        return true
    }
}
