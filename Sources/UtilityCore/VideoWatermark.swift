import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoWatermark {
    struct Source {
        let asset: AVURLAsset
        let size: CGSize
        let duration: Double
        let audioCount: Int
        let orientation: CGAffineTransform
    }

    static func source(_ input: URL) async throws -> Source {
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError.invalid("The input has no readable video track.")
        }
        let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
        let displayed = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, displayed.width.isFinite, displayed.height.isFinite,
              displayed.width >= 2, displayed.height >= 2 else {
            throw ToolError.invalid("Could not read the video dimensions or duration.")
        }
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        return Source(asset: asset, size: displayed, duration: duration, audioCount: audioCount, orientation: transform)
    }

    static func preview(_ input: URL, seconds: Double, mark: WatermarkArtwork, options: WatermarkOptions) async throws -> CGImage {
        let source = try await source(input)
        let visible = try timing(options, duration: source.duration)
        guard seconds.isFinite, (0..<source.duration).contains(seconds) else {
            throw ToolError.invalid("Choose a preview time inside the video.")
        }
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 880, height: 880)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600_000))
        return try WatermarkCanvas.composite(frame.image, mark: visible.contains(frame.actualTime.seconds) ? mark : nil,
                                             options: options)
    }

    static func export(
        _ input: URL, to output: URL, mark: WatermarkArtwork, options: WatermarkOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        guard let executable = options.ffmpegExecutable else {
            throw ToolError.invalid("Choose FFmpeg to export watermarked video.")
        }
        let source = try await source(input)
        let visible = try timing(options, duration: source.duration)
        let size = CGSize(width: source.size.width.rounded(), height: source.size.height.rounded())
        let context = try WatermarkCanvas.bitmap(size: size)
        try WatermarkCanvas.place(mark, on: size, options: options, context: context)
        let manager = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: ".watermark-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let overlay = staging.appending(path: "Watermark.png")
        guard let raster = context.makeImage(),
              let writer = CGImageDestinationCreateWithURL(overlay as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError.invalid("Could not prepare the video overlay.")
        }
        CGImageDestinationAddImage(writer, raster, nil)
        guard CGImageDestinationFinalize(writer) else { throw ToolError.invalid("Could not write the video overlay.") }
        let candidate = staging.appending(path: "Watermarked.mp4")
        let start = decimal(visible.lowerBound)
        let end = decimal(visible.upperBound)
        let width = Int(size.width)
        let height = Int(size.height)
        let orientation = try filters(for: source.orientation)
        let base = (orientation + ["scale=\(width):\(height)", "setsar=1"]).joined(separator: ",")
        let graph = "[0:V:0]\(base)[base];[base][1:v]overlay=0:0:enable='gte(t,\(start))*lt(t,\(end))',pad=ceil(iw/2)*2:ceil(ih/2)*2[video]"
        // The overlay window uses the same source timestamps as the AVFoundation preview.
        await progress(0.12)
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-copyts", "-protocol_whitelist", "file",
            "-noautorotate", "-display_rotation:v:0", "0", "-i", input.path, "-i", overlay.path, "-filter_complex", graph, "-map", "[video]", "-map", "0:a?",
            "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-movflags", "+faststart", candidate.path
        ], directory: staging)
        let result = try await Self.source(candidate)
        guard result.audioCount == source.audioCount,
              result.size == CGSize(width: width + width % 2, height: height + height % 2),
              try await result.asset.load(.isPlayable) else {
            throw ToolError.invalid("The exported video did not retain its expected dimensions and audio.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return "\(input.lastPathComponent) · \(width) × \(height) · MP4"
    }

    private static func filters(for transform: CGAffineTransform) throws -> [String] {
        let values = [transform.a, transform.b, transform.c, transform.d]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1.001 && abs($0.rounded() - $0) < 0.001 }) else {
            throw ToolError.invalid("This video has a display transform that cannot be rendered by the watermark engine.")
        }
        switch values.map({ Int($0.rounded()) }) {
        case [1, 0, 0, 1]: return []
        case [0, 1, -1, 0]: return ["transpose=clock"]
        case [0, -1, 1, 0]: return ["transpose=cclock"]
        case [-1, 0, 0, -1]: return ["hflip", "vflip"]
        case [-1, 0, 0, 1]: return ["hflip"]
        case [1, 0, 0, -1]: return ["vflip"]
        case [0, 1, 1, 0]: return ["transpose=clock", "hflip"]
        case [0, -1, -1, 0]: return ["transpose=clock", "vflip"]
        default: throw ToolError.invalid("This video has an unsupported display orientation.")
        }
    }

    private static func timing(_ options: WatermarkOptions, duration: Double) throws -> Range<Double> {
        let start = options.videoStart
        let end = options.videoEnd ?? duration
        guard start.isFinite, end.isFinite, start >= 0, start < min(end, duration), end <= duration + 0.002 else {
            throw ToolError.invalid("Choose a watermark start and end inside this video.")
        }
        return start..<min(end, duration)
    }

    private static func decimal(_ number: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), number)
    }
}
