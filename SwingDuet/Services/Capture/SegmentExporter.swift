import AVFoundation

/// 本番の切り出し（パススルー書き出し。テストは `ShotPipeline.Exporting` の偽物を差す）
struct SegmentExporter: ShotPipeline.Exporting {
    func exportSegment(of url: URL, range: ClosedRange<Double>) async throws -> URL {
        try await VideoImporter.exportSegment(of: AVURLAsset(url: url), range: range)
    }
}
