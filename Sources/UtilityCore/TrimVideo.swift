import AVFoundation
import Foundation

public enum VideoTrimMode: String, CaseIterable, Identifiable, Sendable {
    case precise = "Precise re-encode"
    case lossless = "Keyframe-aligned copy"

    public var id: Self { self }
}

public struct TrimVideoOptions: Equatable, Sendable {
    public var mode = VideoTrimMode.precise
    public var start: Double = 0
    public var end: Double?
    public var ffmpegExecutable: URL?
    public var ffprobeExecutable: URL?

    public var fileExtension: String { mode == .lossless ? "mkv" : "mp4" }

    public init() {}
}

public struct VideoTrimRange: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public var duration: Double { end - start }

    init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public static func validate(start: Double, end: Double?, duration: Double) throws -> Self {
        let end = end ?? duration
        guard start.isFinite, end.isFinite, duration.isFinite, start >= 0,
              end <= duration, end > start else {
            throw ToolError.invalid("Set an in point before the out point, within the video duration.")
        }
        return Self(start: start, end: end)
    }

    public static func align(
        _ range: Self, to keyframes: [Double], duration: Double
    ) throws -> Self {
        let range = try validate(start: range.start, end: range.end, duration: duration)
        let candidates = keyframes.filter { $0.isFinite && $0 >= 0 && $0 < duration }
        guard let start = candidates.filter({ $0 <= range.start }).max() else {
            throw ToolError.invalid("There is no keyframe at or before the selected in point.")
        }
        let end = candidates.filter { $0 >= range.end }.min() ?? duration
        return try validate(start: start, end: end, duration: duration)
    }
}

public enum TrimVideo {
    public static func duration(of input: URL) async throws -> Double {
        try await duration(of: localAsset(input))
    }

    public static func plannedRange(_ input: URL, options: TrimVideoOptions) async throws -> VideoTrimRange {
        if options.mode == .lossless {
            return try await FFmpegVideoTrim.plan(input, options: options)
        }
        return try await VideoTrimRange.validate(start: options.start, end: options.end, duration: duration(of: input))
    }

    public static func export(
        _ input: URL, to output: URL, options: TrimVideoOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard output.isFileURL, input.isFileURL,
              !FileManager.default.fileExists(atPath: output.path),
              output.standardizedFileURL != input.standardizedFileURL else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let manager = FileManager.default
        let staging = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("trimmed.\(options.fileExtension)")
        let range: VideoTrimRange
        if options.mode == .lossless {
            range = try await FFmpegVideoTrim.export(input, to: candidate, options: options)
        } else {
            range = try await exportPrecise(input, to: candidate, options: options, progress: progress)
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return "\(input.lastPathComponent) · \(range.start.formatted(.number.precision(.fractionLength(0...3))))–\(range.end.formatted(.number.precision(.fractionLength(0...3)))) s · \(options.mode.rawValue)"
    }

    private static func localAsset(_ url: URL) throws -> AVURLAsset {
        guard url.isFileURL else { throw ToolError.invalid("Choose a local video file.") }
        return AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
    }

    private static func duration(of asset: AVURLAsset) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError.invalid("Choose a readable file with a video track.")
        }
        let end = try await track.load(.timeRange).end.seconds
        guard end.isFinite, end > 0 else { throw ToolError.invalid("This video has no finite duration.") }
        return end
    }

    private static func exportPrecise(
        _ input: URL, to candidate: URL, options: TrimVideoOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> VideoTrimRange {
        let asset = try localAsset(input)
        let range = try await VideoTrimRange.validate(start: options.start, end: options.end, duration: duration(of: asset))
        let start = CMTime(seconds: range.start, preferredTimescale: 1_000_000)
        let end = CMTime(seconds: range.end, preferredTimescale: 1_000_000)
        guard start.isNumeric, end.isNumeric, end > start else {
            throw ToolError.invalid("Choose a longer trim range.")
        }
        let editRange = CMTimeRange(start: start, end: end)
        var shouldHaveAudio = false
        for track in try await asset.loadTracks(withMediaType: .audio) {
            if try await track.load(.isEnabled), try await !track.load(.timeRange).intersection(editRange).isEmpty {
                shouldHaveAudio = true
                break
            }
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              export.supportedFileTypes.contains(.mp4) else {
            throw ToolError.invalid("This video cannot be exported as MP4.")
        }
        export.timeRange = editRange
        export.shouldOptimizeForNetworkUse = true
        let states = export.states(updateInterval: 0.2)
        let monitor = Task {
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .exporting(let value) = state { await progress(min(0.99, value.fractionCompleted)) }
            }
        }
        defer { monitor.cancel() }
        try await export.exportMedia(to: candidate, as: .mp4)
        try Task.checkCancellation()

        let result = try localAsset(candidate)
        let videoTracks = try await result.loadTracks(withMediaType: .video)
        let audioTracks = try await result.loadTracks(withMediaType: .audio)
        guard try await result.load(.isPlayable), !videoTracks.isEmpty, !shouldHaveAudio || !audioTracks.isEmpty else {
            throw ToolError.invalid("The trimmed file did not contain the expected playable media.")
        }
        let outputDuration = try await result.load(.duration).seconds
        guard outputDuration.isFinite, outputDuration > 0, abs(outputDuration - range.duration) <= 0.15 else {
            throw ToolError.invalid("The trimmed file did not match the selected duration.")
        }
        return range
    }
}
