import AVFoundation
import Foundation
import UniformTypeIdentifiers

public struct MediaInspectionOptions: Sendable {
    public var ffprobeExecutable: URL?
    package var automaticFFprobeExecutable: URL?

    public init(ffprobeExecutable: URL? = nil) {
        self.ffprobeExecutable = ffprobeExecutable
    }
}

public struct MediaInspectionReport: Sendable {
    public struct Section: Codable, Identifiable, Sendable {
        public let title: String
        public let rows: [Row]
        public var id: String { title }
    }

    public struct Row: Codable, Sendable {
        public let label: String
        public let value: String
    }

    public let sections: [Section]
    public let json: Data

    public var summary: String {
        sections.map { section in
            ([section.title] + section.rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

public enum MediaInspection {
    typealias Section = MediaInspectionReport.Section
    typealias Row = MediaInspectionReport.Row

    public static func inspect(
        _ input: URL, options: MediaInspectionOptions = .init()
    ) async throws -> MediaInspectionReport {
        try Task.checkCancellation()
        let version = try LocalInputFile.Version.read(input)
        let source = version.resolved
        let filename = input.lastPathComponent
        let report: MediaInspectionReport
        if let executable = options.ffprobeExecutable {
            report = try await FFprobeInspection.inspect(source, filename: filename, executable: executable)
        } else {
            do {
                report = try await inspectNatively(source, filename: filename)
            } catch {
                try Task.checkCancellation()
                guard let executable = options.automaticFFprobeExecutable else { throw error }
                try verify(input, version: version)
                report = try await FFprobeInspection.inspect(source, filename: filename, executable: executable, automatic: true)
            }
        }
        try Task.checkCancellation()
        try verify(input, version: version)
        return report
    }

    private static func verify(_ input: URL, version: LocalInputFile.Version) throws {
        guard (try? LocalInputFile.Version.read(input)) == version else {
            throw ToolError.invalid("The media file changed during inspection. Try again.")
        }
    }

    private static func inspectNatively(_ input: URL, filename: String) async throws -> MediaInspectionReport {
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .video || $0.mediaType == .audio }) else {
            throw ToolError.invalid("This file has no readable video or audio tracks.")
        }
        let duration = try await asset.load(.duration)
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let type = UTType(filenameExtension: input.pathExtension)
        var sections = [Section(title: "File", rows: [
            row("Filename", filename),
            row("Container (inferred from extension)", type?.localizedDescription),
            row("Duration", seconds(duration.seconds)),
            row("File size", size.map { bytes(Int64($0)) }),
            row("Overall bitrate (estimated)", size.flatMap { bitrate(Double($0) * 8 / duration.seconds) })
        ])]

        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            if let section = try await trackSection(track, index: index + 1) {
                sections.append(section)
            }
        }

        let tags = try await asset.load(.commonMetadata)
        var tagRows: [Row] = []
        for tag in tags {
            try Task.checkCancellation()
            if let key = tag.commonKey?.rawValue,
               let value = try? await tag.load(.stringValue), !value.isEmpty {
                tagRows.append(row(key, value))
            }
        }
        try Task.checkCancellation()
        if !tagRows.isEmpty { sections.append(Section(title: "Metadata", rows: tagRows)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sections)
        return MediaInspectionReport(sections: sections, json: data)
    }

    private static func trackSection(
        _ track: AVAssetTrack, index: Int
    ) async throws -> Section? {
        let name: String
        switch track.mediaType {
        case .video: name = "Video"
        case .audio: name = "Audio"
        case .subtitle, .text, .closedCaption: name = "Subtitle / captions"
        default: return nil
        }

        let formats = try await track.load(.formatDescriptions)
        let codecNames = formats.compactMap { formatName(CMFormatDescriptionGetMediaSubType($0)) }
        let codecs = codecNames.reduce(into: [String]()) { values, name in
            if !values.contains(name) { values.append(name) }
        }
        let language = try await track.load(.extendedLanguageTag)
        let legacyLanguage = try await track.load(.languageCode)
        let range = try await track.load(.timeRange)
        var rows = [
            row("Codec", codecs.isEmpty ? nil : codecs.joined(separator: ", ")),
            row("Language", language ?? legacyLanguage),
            row("Duration", seconds(range.duration.seconds)),
            row("Track bitrate (estimated)", bitrate(Double(try await track.load(.estimatedDataRate))))
        ]

        if track.mediaType == .video {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displayed = CGRect(origin: .zero, size: size).applying(transform).size
            let rate = Double(try await track.load(.nominalFrameRate))
            rows += [
                row("Dimensions", dimensions(displayed.width, displayed.height)),
                row("Frame rate (nominal)", frameRate(rate)),
                row("Frame timing", frameTiming(track, range: range))
            ]
        } else if track.mediaType == .audio {
            let stream = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            rows += [
                row("Sample rate", stream.flatMap { $0.mSampleRate > 0 ? "\($0.mSampleRate.formatted()) Hz" : nil }),
                row("Channels", stream.flatMap { $0.mChannelsPerFrame > 0 ? String($0.mChannelsPerFrame) : nil })
            ]
        }
        return Section(title: "\(name) track \(index)", rows: rows)
    }

    private static func frameTiming(_ track: AVAssetTrack, range: CMTimeRange) -> String {
        guard range.start.isNumeric, range.duration.isNumeric, range.duration > .zero else { return "Unavailable" }

        // Use independent cursors so the gaps between sampling windows are never counted.
        var sampled = Set<CMTime>()
        var intervals: [Double] = []
        for position in [0.0, 0.25, 0.5, 0.75, 0.9] {
            let start = range.start + CMTimeMultiplyByFloat64(range.duration, multiplier: position)
            guard let cursor = track.makeSampleCursor(presentationTimeStamp: start) else { continue }
            var previous = cursor.presentationTimeStamp
            for _ in 0..<24 {
                guard !Task.isCancelled else { return "Unavailable" }
                guard cursor.stepInPresentationOrder(byCount: 1) == 1 else { break }
                let next = cursor.presentationTimeStamp
                let interval = (next - previous).seconds
                if interval.isFinite, interval > 0, sampled.insert(previous).inserted {
                    intervals.append(interval)
                }
                previous = next
            }
        }
        return frameTiming(intervals: intervals)
    }

    static func frameTiming(intervals: [Double], resolution: Double = 0) -> String {
        guard intervals.count > 2, let shortest = intervals.min(), let longest = intervals.max() else {
            return "Unavailable"
        }
        if longest - shortest > max(0.000_010, shortest * 0.01, resolution * 1.01) {
            return "Variable intervals observed"
        }
        return "Even intervals in sampled frames"
    }

    static func row(_ label: String, _ value: String?) -> Row {
        Row(label: label, value: value.flatMap { $0 == "N/A" || $0.isEmpty ? nil : $0 } ?? "Unavailable")
    }

    static func seconds(_ duration: Double?) -> String? {
        duration.flatMap {
            $0.isFinite && $0 >= 0 ? $0.formatted(.number.precision(.fractionLength(0...3))) + " s" : nil
        }
    }

    static func bytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func bitrate(_ bitsPerSecond: Double?) -> String? {
        bitsPerSecond.flatMap {
            $0.isFinite && $0 > 0 ? ($0 / 1_000).formatted(.number.precision(.fractionLength(0...1))) + " kb/s" : nil
        }
    }

    static func dimensions(_ width: Double?, _ height: Double?) -> String? {
        guard let width, let height, width.isFinite, height.isFinite,
              width > 0, height > 0, width < Double(Int.max), height < Double(Int.max) else { return nil }
        return "\(Int(width.rounded())) × \(Int(height.rounded()))"
    }

    static func frameRate(_ fps: Double?) -> String? {
        fps.flatMap { $0.isFinite && $0 > 0 ? $0.formatted(.number.precision(.fractionLength(0...3))) + " fps" : nil }
    }

    private static func formatName(_ code: FourCharCode) -> String? {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
