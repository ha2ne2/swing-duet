import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

/// PhotosPicker から動画ファイルを受け取るための Transferable。
/// 240fps スロー動画も、フォトライブラリからは高フレームレートの元ファイルとして渡される。
struct ImportedMovie: Transferable {
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

struct VideoMetadata {
    let duration: Double
    let frameRate: Double
}

enum VideoImporterError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "動画トラックが見つかりませんでした。"
        }
    }
}

func loadVideoMetadata(url: URL) async throws -> VideoMetadata {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw VideoImporterError.noVideoTrack
    }
    let fps = try await track.load(.nominalFrameRate)
    return VideoMetadata(duration: duration, frameRate: Double(fps))
}
