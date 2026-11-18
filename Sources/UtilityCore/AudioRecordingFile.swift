import AVFoundation
import Foundation

public struct AudioRecordingFile: Equatable, Sendable {
    public let url: URL
    public let duration: Double

    public static func inspect(_ url: URL) async throws -> Self {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("No recording file was written.")
        }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
        let (playable, duration, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
        guard playable, duration.seconds.isFinite, duration.seconds > 0,
              tracks.contains(where: { $0.mediaType == .audio }) else {
            throw ToolError.invalid("The recording did not contain playable audio.")
        }
        return Self(url: url, duration: duration.seconds)
    }

    public func save(to output: URL) async throws {
        try await RecordingFileSave.copy(url, to: output)
    }
}
