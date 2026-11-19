import AVFoundation

public struct ScreenRecordingFile: Equatable, Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let duration: Double
    public let dimensions: CGSize
    public let audioTrackCount: Int

    public static func inspect(_ url: URL) async throws -> Self {
        guard url.isFileURL else { throw ToolError.invalid("Choose a local recording file.") }
        let asset = localAsset(url)
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }), try await asset.load(.isPlayable) else {
            throw ToolError.invalid("The recording did not contain playable video.")
        }
        let (range, size, transform) = try await video.load(.timeRange, .naturalSize, .preferredTransform)
        let dimensions = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        guard range.duration.seconds.isFinite, range.duration.seconds > 0,
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else {
            throw ToolError.invalid("The recording did not report valid timing or dimensions.")
        }
        return Self(url: url, duration: range.duration.seconds, dimensions: dimensions,
                    audioTrackCount: tracks.filter { $0.mediaType == .audio }.count)
    }

    public func save(to output: URL) async throws {
        try await RecordingFileSave.copy(url, to: output)
    }

    public static func join(_ files: [Self], to output: URL) async throws -> Self {
        guard files.count > 1 else { throw ToolError.invalid("At least two recording segments are required.") }
        let manager = FileManager.default
        guard output.isFileURL, !manager.fileExists(atPath: output.path),
              !files.contains(where: { $0.url.standardizedFileURL == output.standardizedFileURL }) else {
            throw ToolError.invalid("Choose a new local recording file.")
        }
        let staging = output.deletingLastPathComponent().appending(path: ".screen-join-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "combined.mp4")
        let slots = files.map(\.audioTrackCount).max() ?? 0
        var options = VideoMergeOptions()
        options.mode = .passthrough
        if slots <= 1 {
            do {
                _ = try await VideoMerge.export(files.map(\.url), to: candidate, options: options) { _ in }
            } catch {
                try Task.checkCancellation()
                options.mode = .normalize
                _ = try await VideoMerge.export(files.map(\.url), to: candidate, options: options) { _ in }
            }
        } else {
            try await joinMultitrack(files, slots: slots, to: candidate)
        }
        let result = try await inspect(candidate)
        let expectedDuration = files.reduce(0) { $0 + $1.duration }
        guard result.audioTrackCount == slots, abs(result.duration - expectedDuration) < 0.2 else {
            throw ToolError.invalid("The combined recording did not preserve the expected audio and timing.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        return Self(url: output, duration: result.duration, dimensions: result.dimensions,
                    audioTrackCount: result.audioTrackCount)
    }

    private static func localAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
    }

    private static func joinMultitrack(_ files: [Self], slots: Int, to output: URL) async throws {
        let timeline = AVMutableComposition()
        guard let picture = timeline.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError.invalid("Could not build the recording timeline.")
        }
        let audio = (0..<slots).compactMap { _ in
            timeline.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        guard audio.count == slots else { throw ToolError.invalid("Could not build all recording audio tracks.") }

        var cursor = CMTime.zero
        for file in files {
            try Task.checkCancellation()
            let source = localAsset(file.url)
            guard let video = try await source.loadTracks(withMediaType: .video).first else {
                throw ToolError.invalid("A recording segment is missing its video track.")
            }
            let range = try await video.load(.timeRange)
            try picture.insertTimeRange(range, of: video, at: cursor)
            if cursor == .zero { picture.preferredTransform = try await video.load(.preferredTransform) }
            let tracks = try await source.loadTracks(withMediaType: .audio)
            for (target, track) in zip(audio, tracks) {
                let overlap = try await track.load(.timeRange).intersection(range)
                if !overlap.isEmpty {
                    try target.insertTimeRange(overlap, of: track, at: cursor + (overlap.start - range.start))
                }
            }
            cursor = cursor + range.duration
        }
        guard let exporter = AVAssetExportSession(asset: timeline, presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mp4) else {
            throw ToolError.invalid("The recording audio tracks could not be combined in MP4.")
        }
        try await exporter.exportMedia(to: output, as: .mp4)
    }
}
