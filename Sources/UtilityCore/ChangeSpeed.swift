import AVFoundation

public struct ChangeSpeedOptions: Equatable, Sendable {
    public static let supportedMultipliers = 0.25...4.0

    public var multiplier = 1.0
    public var preservesPitch = true
    public var ffmpegExecutable: URL?

    public init() {}

    public var isValid: Bool {
        multiplier.isFinite && Self.supportedMultipliers.contains(multiplier)
    }
}

public enum ChangeSpeed {
    public struct SourceInfo: Sendable {
        public let duration: Double
        public let hasAudio: Bool
    }

    public static func sourceDuration(_ input: URL) async throws -> Double {
        let asset = try localAsset(input)
        guard let video = try await primaryTrack(.video, in: asset) else {
            throw ToolError.invalid("Choose a readable file with a video track.")
        }
        return try await videoDuration(video).seconds
    }

    public static func sourceInfo(_ input: URL) async throws -> SourceInfo {
        let asset = try localAsset(input)
        guard let video = try await primaryTrack(.video, in: asset) else {
            throw ToolError.invalid("Choose a readable file with a video track.")
        }
        let duration = try await videoDuration(video).seconds
        let hasAudio = try await primaryTrack(.audio, in: asset) != nil
        return SourceInfo(duration: duration, hasAudio: hasAudio)
    }

    public static func export(
        _ input: URL, to output: URL, options: ChangeSpeedOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        try await render(input, to: output, options: options, preview: false, progress: progress)
    }

    public static func preview(_ input: URL, to output: URL, options: ChangeSpeedOptions) async throws {
        _ = try await render(input, to: output, options: options, preview: true) { _ in }
    }

    private static func render(
        _ input: URL, to output: URL, options: ChangeSpeedOptions, preview: Bool,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard options.isValid else {
            throw ToolError.invalid("Choose a speed between 0.25× and 4×.")
        }
        let asset = try localAsset(input)
        guard output.isFileURL,
              output.standardizedFileURL != input.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        try Task.checkCancellation()
        guard let video = try await primaryTrack(.video, in: asset) else {
            throw ToolError.invalid("Choose a readable file with a video track.")
        }
        let videoRange = try await video.load(.timeRange)
        let fullLength = videoRange.end
        guard fullLength.seconds.isFinite, fullLength.seconds > 0 else {
            throw ToolError.invalid("The video has no finite duration.")
        }
        let previewLimit = CMTime(seconds: min(5, 8 * options.multiplier), preferredTimescale: 90_000)
        let segments = preview ? try? await video.load(.segments) : nil
        let firstMedia = segments?.first { !$0.isEmpty }?.timeMapping.target.start
        let lastMedia = segments?.last { !$0.isEmpty }?.timeMapping.target.end
        let start = preview ? CMTimeMaximum(.zero, firstMedia ?? videoRange.start) : .zero
        let available = fullLength - start
        let visible = (lastMedia ?? fullLength) - start
        let duration = preview ? CMTimeMinimum(visible, previewLimit) : fullLength
        let editRange = CMTimeRange(start: start, duration: duration)
        guard editRange.duration.seconds.isFinite, editRange.duration.seconds > 0 else {
            throw ToolError.invalid("The selected video has no frames to preview.")
        }
        let audio = try await primaryTrack(.audio, in: asset)
        let manager = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: ".speed-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Adjust Speed.mp4")
        let expectsAudio: Bool
        if let audio, !options.preservesPitch, options.multiplier != 1 {
            // AVAssetExportSession can stall while encoding scaled PCM with
            // Varispeed. Use FFmpeg's explicit rate conversion for this mode.
            guard let executable = options.ffmpegExecutable else {
                throw ToolError.invalid("Choose an FFmpeg executable to change both audio speed and pitch.")
            }
            let includeAudio = preview ? !(try await audio.load(.timeRange)).intersection(editRange).isEmpty : true
            try await FFmpegChangeSpeed.export(input, to: candidate, multiplier: options.multiplier,
                                               executable: executable,
                                               start: start.seconds,
                                               durationLimit: duration < available ? duration.seconds / options.multiplier : nil,
                                               includeAudio: includeAudio)
            expectsAudio = includeAudio
        } else {
            expectsAudio = try await nativeExport(video: video, audio: audio, editRange: editRange,
                                                  to: candidate, multiplier: options.multiplier, progress: progress)
        }
        try Task.checkCancellation()
        let result = try localAsset(candidate)
        let videoTracks = try await result.loadTracks(withMediaType: .video)
        let audioTracks = try await result.loadTracks(withMediaType: .audio)
        guard let resultVideo = videoTracks.first, !expectsAudio || !audioTracks.isEmpty,
              try await result.load(.isPlayable) else {
            throw ToolError.invalid("The export did not contain all expected playable media.")
        }
        let (resultRange, resultRate) = try await resultVideo.load(.timeRange, .nominalFrameRate)
        let expectedEnd = duration.seconds / options.multiplier
        let tolerance = resultRate.isFinite && resultRate > 0 ? max(0.065, 2 / Double(resultRate)) : 0.1
        guard resultRange.end.seconds.isFinite, abs(resultRange.end.seconds - expectedEnd) <= tolerance else {
            throw ToolError.invalid("The exported video did not match the selected playback speed.")
        }
        if let resultAudio = audioTracks.first {
            let resultEnd = try await resultAudio.load(.timeRange).end.seconds
            guard resultEnd.isFinite, resultEnd <= expectedEnd + tolerance else {
                throw ToolError.invalid("The exported audio extends past the adjusted video.")
            }
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        let speed = options.multiplier.formatted(.number.precision(.fractionLength(0...4)))
        return "\(input.lastPathComponent) · \(speed)× · MP4"
    }

    private static func nativeExport(
        video: AVAssetTrack, audio: AVAssetTrack?, editRange: CMTimeRange,
        to output: URL, multiplier: Double, progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> Bool {
        let composition = AVMutableComposition()

        let videoTrack = try await insert(video, within: editRange, into: composition)
        guard let videoTrack else { throw ToolError.invalid("The video track has no editable frames.") }
        videoTrack.preferredTransform = try await video.load(.preferredTransform)
        let audioTrack: AVMutableCompositionTrack?
        if let audio {
            audioTrack = try await insert(audio, within: editRange, into: composition)
        } else {
            audioTrack = nil
        }
        let scaledDuration = CMTimeMultiplyByFloat64(editRange.duration, multiplier: 1 / multiplier)
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: editRange.duration), toDuration: scaledDuration)

        try Task.checkCancellation()
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              export.supportedFileTypes.contains(.mp4) else {
            throw ToolError.invalid("This video cannot be exported as MP4.")
        }
        export.timeRange = CMTimeRange(start: .zero, duration: scaledDuration)
        export.audioTimePitchAlgorithm = .spectral
        export.shouldOptimizeForNetworkUse = true
        let states = export.states(updateInterval: 0.2)
        let monitor = Task {
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .exporting(let exportProgress) = state {
                    await progress(min(0.99, exportProgress.fractionCompleted))
                }
            }
        }
        defer { monitor.cancel() }
        try await export.exportMedia(to: output, as: .mp4)
        return audioTrack != nil
    }

    private static func localAsset(_ url: URL) throws -> AVURLAsset {
        guard url.isFileURL else { throw ToolError.invalid("Choose a local video file.") }
        return AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
    }

    private static func primaryTrack(_ type: AVMediaType, in asset: AVAsset) async throws -> AVAssetTrack? {
        for track in try await asset.loadTracks(withMediaType: type) {
            if try await track.load(.isEnabled) { return track }
        }
        return nil
    }

    private static func videoDuration(_ video: AVAssetTrack) async throws -> CMTime {
        let range = try await video.load(.timeRange)
        guard range.end.seconds.isFinite, range.end.seconds > 0 else {
            throw ToolError.invalid("The video has no finite duration.")
        }
        return range.end
    }

    private static func insert(
        _ source: AVAssetTrack, within editRange: CMTimeRange, into composition: AVMutableComposition
    ) async throws -> AVMutableCompositionTrack? {
        let range = try await source.load(.timeRange).intersection(editRange)
        guard !range.isEmpty else { return nil }
        guard let track = composition.addMutableTrack(withMediaType: source.mediaType,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError.invalid("Could not create the adjusted media track.")
        }
        try track.insertTimeRange(range, of: source, at: range.start - editRange.start)
        return track
    }
}
