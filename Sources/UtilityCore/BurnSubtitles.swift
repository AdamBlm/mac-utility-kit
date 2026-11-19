import AVFoundation
import Foundation
import ImageIO

public enum SubtitlePosition: String, CaseIterable, Identifiable, Sendable {
    case top = "Top"
    case middle = "Middle"
    case bottom = "Bottom"

    public var id: Self { self }

    var alignment: Int {
        switch self {
        case .top: 8
        case .middle: 5
        case .bottom: 2
        }
    }
}

public enum SubtitleBackground: String, CaseIterable, Identifiable, Sendable {
    case outline = "Outline"
    case translucent = "Translucent box"
    case solid = "Solid box"

    public var id: Self { self }
}

public struct BurnSubtitlesOptions: Equatable, Sendable {
    public var srt = ""
    public var offset = 0.0
    public var fontSize = 24
    public var textRGB: UInt32 = 0xFFFFFF
    public var background: SubtitleBackground = .translucent
    public var backgroundRGB: UInt32 = 0x000000
    public var position: SubtitlePosition = .bottom
    public var ffmpegExecutable: URL?

    package var engineIssue: String? {
        ffmpegExecutable.map(ExternalTool.isExecutable) == true ? nil : "Choose an FFmpeg executable with libass."
    }

    package var hasSubtitles: Bool { !srt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    package var subtitleIssue: String? {
        do {
            _ = try SubRip.parse(srt)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public init() {}
}

public struct BurnSubtitlesPlan: Sendable {
    public let cues: [SubtitleCue]
    public let removed: Int
    public let clipped: Int
}

public enum BurnSubtitles {
    public static func plan(duration: Double, options: BurnSubtitlesOptions) throws -> BurnSubtitlesPlan {
        guard options.offset.isFinite, abs(options.offset) <= 86_400 else {
            throw ToolError.invalid("Choose an offset between −86,400 and 86,400 seconds.")
        }
        guard (8...80).contains(options.fontSize), options.textRGB <= 0xFFFFFF, options.backgroundRGB <= 0xFFFFFF else {
            throw ToolError.invalid("Choose a font size from 8 to 80 and valid subtitle colors.")
        }
        guard duration.isFinite, duration > 0, duration < 4_000_000_000 else {
            throw ToolError.invalid("The video must have a finite positive duration.")
        }
        let limit = Int((duration * 1_000).rounded(.down))
        let offset = Int((options.offset * 1_000).rounded())
        let source = try SubRip.parse(options.srt)
        var clipped = 0
        let adjusted = source.compactMap { cue -> SubtitleCue? in
            let shiftedStart = cue.startMilliseconds + offset
            let shiftedEnd = cue.endMilliseconds + offset
            let start = max(0, shiftedStart)
            let end = min(limit, shiftedEnd)
            guard start < end else { return nil }
            if start != shiftedStart || end != shiftedEnd { clipped += 1 }
            return SubtitleCue(startMilliseconds: start, endMilliseconds: end, text: cue.text)
        }
        guard !adjusted.isEmpty else { throw ToolError.invalid("No subtitle cues fall inside the video after applying the offset.") }
        return BurnSubtitlesPlan(cues: adjusted, removed: source.count - adjusted.count, clipped: clipped)
    }

    public static func preview(_ input: URL, at seconds: Double, options: BurnSubtitlesOptions) async throws -> CGImage {
        if let issue = options.engineIssue { throw ToolError.invalid(issue) }
        let duration = try await TrimVideo.duration(of: input)
        guard seconds.isFinite, seconds >= 0, seconds < duration else {
            throw ToolError.invalid("Choose a playhead position inside this video.")
        }
        let plan = try plan(duration: duration, options: options)
        return try await staging(in: FileManager.default.temporaryDirectory) { directory in
            let output = directory.appendingPathComponent("preview.png")
            try await FFmpegBurnSubtitles.preview(input, at: seconds, cues: plan.cues, to: output, options: options)
            let data = try Data(contentsOf: output)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ToolError.invalid("The preview frame could not be read.")
            }
            return image
        }
    }

    public static func export(
        _ input: URL, to output: URL, options: BurnSubtitlesOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard input.isFileURL, output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local MP4 file.")
        }
        if let issue = options.engineIssue { throw ToolError.invalid(issue) }
        let duration = try await TrimVideo.duration(of: input)
        let plan = try plan(duration: duration, options: options)
        let source = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
        let expectedAudioCount = try await source.loadTracks(withMediaType: .audio).count
        let ratedDuration = try await source.load(.duration).seconds
        return try await staging(in: output.deletingLastPathComponent()) { directory in
            let candidate = directory.appendingPathComponent("captioned.mp4")
            try await FFmpegBurnSubtitles.export(input, cues: plan.cues, to: candidate, options: options)
            await progress(0.9)
            let asset = AVURLAsset(url: candidate)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let outputDuration = try await asset.load(.duration).seconds
            guard try await asset.load(.isPlayable), !video.isEmpty, audio.count == expectedAudioCount,
                  outputDuration.isFinite, abs(outputDuration - ratedDuration) <= 0.2 else {
                throw ToolError.invalid("The captioned MP4 could not be verified with its expected video and audio.")
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: candidate, to: output)
            await progress(1)
            return "\(input.lastPathComponent) · \(plan.cues.count) cues burned in · \(plan.clipped) clipped · \(plan.removed) outside video"
        }
    }

    private static func staging<T>(in folder: URL, work: (URL) async throws -> T) async throws -> T {
        let manager = FileManager.default
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        return try await work(directory)
    }
}
