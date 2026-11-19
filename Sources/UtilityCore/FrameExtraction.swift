import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameImageFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG"
    case jpeg = "JPEG"
    case heic = "HEIC"

    public var id: Self { self }
    public var supportsQuality: Bool { self != .png }

    public var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

public enum FrameSelection: String, CaseIterable, Identifiable, Sendable {
    case timestamps = "Timestamps"
    case interval = "Fixed interval"

    public var id: Self { self }
}

public enum FrameNaming: String, CaseIterable, Identifiable, Sendable {
    case time = "Timestamp"
    case sequence = "Sequence"

    public var id: Self { self }
}

public struct FrameExtractionOptions: Sendable {
    public var selection = FrameSelection.timestamps
    public var timestamps: [Double] = []
    public var interval: Double = 1
    public var format = FrameImageFormat.png
    public var quality: Double = 0.85
    public var naming = FrameNaming.time

    public init() {}
}

public struct FrameExtractionResult: Sendable {
    public let outputs: [URL]
    public let failures: [String]
}

public enum FrameExtraction {
    public static let maximumFrames = 500

    /// Returns strictly increasing times. An empty timestamp list exports the first frame.
    public static func times(duration: Double, options: FrameExtractionOptions) throws -> [Double] {
        guard duration.isFinite, duration > 0 else {
            throw ToolError.invalid("The video must have a finite positive duration.")
        }
        return try times(in: 0..<duration, options: options)
    }

    package static func times(in bounds: Range<Double>, options: FrameExtractionOptions) throws -> [Double] {
        switch options.selection {
        case .timestamps:
            let times = options.timestamps.isEmpty ? [bounds.lowerBound] : options.timestamps
            guard times.count <= maximumFrames else { throw tooManyFrames() }
            guard times.allSatisfy({ $0.isFinite && bounds.contains($0) }) else {
                throw ToolError.invalid("Each timestamp must be at or after the first video frame and before the end of the video.")
            }
            return Set(times).sorted()
        case .interval:
            let interval = options.interval
            guard interval.isFinite, interval > 0 else {
                throw ToolError.invalid("Enter an interval greater than zero seconds.")
            }
            let firstExcess = bounds.lowerBound + Double(maximumFrames) * interval
            guard firstExcess >= bounds.upperBound else { throw tooManyFrames() }
            return Array((0..<maximumFrames).map { bounds.lowerBound + Double($0) * interval }
                .prefix { $0 < bounds.upperBound })
        }
    }

    public static func duration(of input: URL) async throws -> Double {
        try await load(input).trackEnd
    }

    package static func timeBounds(of input: URL) async throws -> Range<Double> {
        try await load(input).bounds
    }

    public static func preview(_ input: URL, at seconds: Double) async throws -> CGImage {
        let source = try await load(input)
        guard seconds.isFinite, source.bounds.contains(seconds) else {
            throw ToolError.invalid("Select a timestamp within the video.")
        }
        let generator = makeGenerator(for: source.asset)
        generator.maximumSize = CGSize(width: 640, height: 360)
        return try await image(at: seconds, start: source.start, generator: generator)
    }

    public static func export(
        _ input: URL, into directory: URL, options: FrameExtractionOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws -> FrameExtractionResult {
        if options.format.supportsQuality {
            guard options.quality.isFinite, (0...1).contains(options.quality) else {
                throw ToolError.invalid("Image quality must be between 0% and 100%.")
            }
        }
        let type = options.format.contentType.identifier
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type) == true else {
            throw ToolError.invalid("This Mac cannot encode \(options.format.rawValue) images.")
        }
        let source = try await load(input)
        let times = try times(in: source.bounds, options: options)
        let generator = makeGenerator(for: source.asset)
        let manager = FileManager.default
        var outputs: [URL] = []
        var failures: [String] = []
        do {
            for (index, time) in times.enumerated() {
                try Task.checkCancellation()
                let label = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), time)
                let sequence = String(format: "%03d", index + 1)
                let stem = options.naming == .time ? "Frame-\(sequence)-\(label)s" : "Frame-\(sequence)"
                let candidate = directory.appendingPathComponent(UUID().uuidString)
                let output = directory.appendingPathComponent("\(stem).\(options.format.fileExtension)")
                do {
                    let frame = try await image(at: time, start: source.start, generator: generator)
                    try Task.checkCancellation()
                    try write(frame, to: candidate, options: options)
                    try Task.checkCancellation()
                    try manager.moveItem(at: candidate, to: output)
                    outputs.append(output)
                } catch {
                    try? manager.removeItem(at: candidate)
                    try Task.checkCancellation()
                    failures.append("\(label)s: \(error.localizedDescription)")
                }
                await progress(Double(index + 1) / Double(times.count))
            }
            try Task.checkCancellation()
            return FrameExtractionResult(outputs: outputs, failures: failures)
        } catch {
            for output in outputs { try? manager.removeItem(at: output) }
            throw error
        }
    }

    private static func load(_ input: URL) async throws -> (asset: AVURLAsset, start: CMTime, bounds: Range<Double>, trackEnd: Double) {
        guard input.isFileURL else { throw ToolError.invalid("Choose a local video file.") }
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError.invalid("The selected file has no video track.")
        }
        let range = try await video.load(.timeRange)
        // QuickTime edit lists can include an empty segment inside the track's time range.
        let segments = try? await video.load(.segments)
        try Task.checkCancellation()
        let firstMedia = segments?.first { !$0.isEmpty }?.timeMapping.target.start ?? range.start
        let lastMedia = segments?.last { !$0.isEmpty }?.timeMapping.target.end ?? range.end
        let start = CMTimeMaximum(CMTimeMaximum(range.start, firstMedia), .zero)
        let end = CMTimeMinimum(range.end, lastMedia)
        guard start.isNumeric, end.isNumeric, end.seconds > start.seconds else {
            throw ToolError.invalid("The video must have a finite positive duration.")
        }
        return (asset, start, start.seconds..<end.seconds, range.end.seconds)
    }

    private static func makeGenerator(for asset: AVURLAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    private static func image(at seconds: Double, start: CMTime, generator: AVAssetImageGenerator) async throws -> CGImage {
        try Task.checkCancellation()
        let time = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        guard time.isNumeric else { throw ToolError.invalid("Could not represent the selected timestamp.") }
        // Round toward the start if timescale conversion otherwise rounds up to the end.
        let seekTime = time.seconds > seconds && time.value > 0
            ? CMTime(value: time.value - 1, timescale: time.timescale)
            : time
        return try await generator.image(at: CMTimeMaximum(start, seekTime)).image
    }

    private static func write(_ image: CGImage, to url: URL, options: FrameExtractionOptions) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
            options.format.contentType.identifier as CFString, 1, nil) else {
            throw ToolError.invalid("Could not create the output image.")
        }
        let properties = options.format.supportsQuality
            ? [kCGImageDestinationLossyCompressionQuality: options.quality] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolError.invalid("Could not write the output image.")
        }
    }

    private static func tooManyFrames() -> ToolError {
        ToolError.invalid("Export up to \(maximumFrames) frames per video. Remove timestamps or increase the interval.")
    }
}
