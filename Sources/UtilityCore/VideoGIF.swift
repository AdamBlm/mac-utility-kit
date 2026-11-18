import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GIFPalette: Int, CaseIterable, Identifiable, Sendable {
    case compact = 64
    case balanced = 128
    case detailed = 256

    public var id: Self { self }
}

public enum GIFLoop: String, CaseIterable, Identifiable, Sendable {
    case once = "Play once"
    case forever = "Loop forever"
    case repeatCount = "Repeat"

    public var id: Self { self }
}

public struct VideoGIFOptions: Equatable, Sendable {
    public var start = 0.0
    public var end: Double?
    public var width = 480
    public var fps = 15
    public var palette = GIFPalette.detailed
    public var dithering = true
    public var loop = GIFLoop.forever
    public var repetitions = 2
    public var ffmpegExecutable: URL?

    public init() {}

    var loopValue: Int {
        switch loop {
        case .once: -1
        case .forever: 0
        case .repeatCount: repetitions
        }
    }
}

public struct VideoGIFPlan: Sendable {
    public let range: VideoTrimRange
    public let frameCount: Int
    public let shouldWarnAboutSize: Bool
}

public struct VideoGIFPreview: Sendable {
    public let data: Data
    public let estimatedBytes: Int
    public let duration: Double
    public let showsFullClip: Bool
}

public enum VideoGIF {
    public static func plan(duration: Double, options: VideoGIFOptions) throws -> VideoGIFPlan {
        guard (16...1_280).contains(options.width), (5...30).contains(options.fps) else {
            throw ToolError.invalid("Choose a width from 16 to 1,280 pixels and a frame rate from 5 to 30 fps.")
        }
        guard options.loop != .repeatCount || (1...99).contains(options.repetitions) else {
            throw ToolError.invalid("Choose between 1 and 99 repeats.")
        }
        let range = try VideoTrimRange.validate(start: options.start, end: options.end, duration: duration)
        let frames = range.duration * Double(options.fps)
        guard frames.isFinite, frames <= 1_200 else {
            throw ToolError.invalid("Choose a shorter clip or a lower frame rate. GIF exports support up to 1,200 frames.")
        }
        guard frames >= 2 else {
            throw ToolError.invalid("Select a clip long enough for at least two GIF frames.")
        }
        let frameCount = Int(frames.rounded(.up))
        return VideoGIFPlan(range: range, frameCount: frameCount,
                            shouldWarnAboutSize: frameCount >= 300 || Double(options.width) * Double(frameCount) >= 200_000)
    }

    public static func preview(_ input: URL, options: VideoGIFOptions) async throws -> VideoGIFPreview {
        let duration = try await TrimVideo.duration(of: input)
        let plan = try plan(duration: duration, options: options)
        let seconds = min(plan.range.duration, 2)
        let sample = VideoTrimRange(start: plan.range.start, end: plan.range.start + seconds)
        let showsFullClip = seconds == plan.range.duration
        return try await staging(in: FileManager.default.temporaryDirectory) { directory in
            let output = directory.appendingPathComponent("preview.gif")
            try await FFmpegVideoGIF.encode(input, range: sample, to: output, options: options) { _ in }
            let data = try Data(contentsOf: output)
            let bytes = Int((Double(data.count) * plan.range.duration / seconds).rounded())
            return VideoGIFPreview(data: data, estimatedBytes: bytes, duration: seconds, showsFullClip: showsFullClip)
        }
    }

    public static func export(
        _ input: URL, to output: URL, options: VideoGIFOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path),
              output.standardizedFileURL != input.standardizedFileURL else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let duration = try await TrimVideo.duration(of: input)
        let plan = try plan(duration: duration, options: options)
        return try await staging(in: output.deletingLastPathComponent()) { directory in
            let candidate = directory.appendingPathComponent("animation.gif")
            try await FFmpegVideoGIF.encode(input, range: plan.range, to: candidate, options: options, progress: progress)
            let count = try verifyAnimation(candidate, range: plan.range, options: options)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: candidate, to: output)
            await progress(1)
            return "\(input.lastPathComponent) · \(count) GIF frames · \(options.loop.rawValue)"
        }
    }

    private static func verifyAnimation(_ url: URL, range: VideoTrimRange, options: VideoGIFOptions) throws -> Int {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(image) as String? == UTType.gif.identifier,
              CGImageSourceGetStatus(image) == .statusComplete else {
            throw ToolError.invalid("The GIF could not be reopened after encoding.")
        }
        let count = CGImageSourceGetCount(image)
        guard count >= 2 else { throw ToolError.invalid("The GIF did not contain an animation.") }
        guard try GIFLoopMetadata.read(url) == options.loopValue else {
            throw ToolError.invalid("The GIF loop setting could not be verified.")
        }
        var timing = 0.0
        for index in 0..<count {
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any]
            let frame = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (frame?[kCGImagePropertyGIFUnclampedDelayTime] ?? frame?[kCGImagePropertyGIFDelayTime]) as? NSNumber
            guard CGImageSourceGetStatusAtIndex(image, index) == .statusComplete, let delay, delay.doubleValue > 0 else {
                throw ToolError.invalid("The GIF contains an unreadable frame.")
            }
            timing += delay.doubleValue
        }
        guard abs(timing - range.duration) <= 1.1 / Double(options.fps) + 0.01 else {
            throw ToolError.invalid("The animation timing did not match the selected clip.")
        }
        return count
    }

    private static func staging<T>(in folder: URL, work: (URL) async throws -> T) async throws -> T {
        let manager = FileManager.default
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        return try await work(directory)
    }
}
