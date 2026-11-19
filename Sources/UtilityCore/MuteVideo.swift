import AVFoundation
import Foundation

public struct MuteVideoOptions: Equatable, Sendable {
    public enum Removal: String, CaseIterable, Identifiable, Sendable {
        case all = "All audio tracks", selected = "Selected audio tracks"
        public var id: Self { self }
    }

    public enum Container: String, CaseIterable, Identifiable, Sendable {
        case original = "Same as input", movie = "MOV", mp4 = "MP4"
        public var id: Self { self }
    }

    public var removal = Removal.all
    public var container = Container.original
    public var removedTrackIDs: [URL: Set<Int32>] = [:]

    public init() {}

    public func removes(_ track: MuteVideoStream, from input: URL) -> Bool {
        track.isAudio && (removal == .all || removedTrackIDs[input, default: []].contains(track.id))
    }
}

public struct MuteVideoStream: Sendable, Identifiable {
    public let id: Int32
    public let kind: String
    public let codecs: [String]
    public let language: String?
    public let channels: Int?
    public let audioIndex: Int?
    public var isAudio: Bool { audioIndex != nil }
}

public enum MuteVideo {
    private enum Format: String {
        case mov, mp4, m4v

        var fileType: AVFileType {
            switch self {
            case .mov: .mov
            case .mp4: .mp4
            case .m4v: .m4v
            }
        }
    }

    public static func outputExtension(_ input: URL, options: MuteVideoOptions) throws -> String {
        try format(for: input, options: options).rawValue
    }

    public static func inspect(_ input: URL) async throws -> [MuteVideoStream] {
        let asset = try localAsset(input)
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw ToolError.invalid("This file has no readable video track.")
        }
        var streams: [MuteVideoStream] = []
        var audioCount = 0
        for track in tracks {
            try Task.checkCancellation()
            let formats = try await track.load(.formatDescriptions)
            let (languageTag, languageCode) = try await track.load(.extendedLanguageTag, .languageCode)
            let channels = track.mediaType == .audio ? formats.compactMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
            }.first.map(Int.init) : nil
            let codecs = Array(Set(formats.map { codecName(CMFormatDescriptionGetMediaSubType($0)) })).sorted()
            let audioIndex = track.mediaType == .audio ? audioCount : nil
            if audioIndex != nil { audioCount += 1 }
            streams.append(MuteVideoStream(id: track.trackID, kind: mediaName(track.mediaType), codecs: codecs,
                                           language: languageTag ?? languageCode, channels: channels, audioIndex: audioIndex))
        }
        return streams
    }

    public static func checkCompatibility(_ input: URL, options: MuteVideoOptions) async throws {
        let format = try format(for: input, options: options)
        _ = try await prepare(input, format: format, options: options)
    }

    public static func export(
        _ input: URL, to output: URL, options: MuteVideoOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let format = try format(for: input, options: options)
        guard output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let prepared = try await prepare(input, format: format, options: options)
        defer { withExtendedLifetime(prepared.asset) {} }
        let session = prepared.session
        session.metadata = try await prepared.asset.load(.metadata)
        try Task.checkCancellation()
        let manager = FileManager.default
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent(".mute-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("Muted." + format.rawValue)
        let states = session.states(updateInterval: 0.2)
        let monitor = Task {
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .exporting(let fraction) = state {
                    await progress(min(0.99, fraction.fractionCompleted))
                }
            }
        }
        defer { monitor.cancel() }
        try await session.exportMedia(to: candidate, as: format.fileType)
        try Task.checkCancellation()

        let result = try localAsset(candidate)
        let actual = try await signatures(for: result.load(.tracks))
        let expected = try await signatures(for: prepared.retained)
        guard actual == expected, try await result.load(.isPlayable) else {
            throw ToolError.invalid("The output could not preserve every retained stream in this container.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return "\(input.lastPathComponent) · \(prepared.removedCount) audio track\(prepared.removedCount == 1 ? "" : "s") removed · Video copied"
    }

    private struct Prepared {
        let asset: AVURLAsset
        let session: AVAssetExportSession
        let retained: [AVAssetTrack]
        let removedCount: Int
    }

    private static func prepare(_ input: URL, format: Format, options: MuteVideoOptions) async throws -> Prepared {
        try Task.checkCancellation()
        let asset = try localAsset(input)
        let sourceTracks = try await asset.load(.tracks)
        let audioIDs = Set(sourceTracks.filter { $0.mediaType == .audio }.map(\.trackID))
        guard sourceTracks.contains(where: { $0.mediaType == .video }) else {
            throw ToolError.invalid("This file has no readable video track.")
        }
        guard !audioIDs.isEmpty else {
            throw ToolError.invalid("This video already has no audio tracks.")
        }
        let selected = options.removal == .all ? audioIDs : options.removedTrackIDs[input, default: []]
        guard !selected.isEmpty else {
            throw ToolError.invalid("Select at least one audio track to remove from this video.")
        }
        guard selected.isSubset(of: audioIDs) else {
            throw ToolError.invalid("The selected audio tracks have changed. Select them again.")
        }
        let retained = sourceTracks.filter { !selected.contains($0.trackID) }
        let composition = AVMutableComposition()
        var targets: [Int32: AVMutableCompositionTrack] = [:]
        for source in retained {
            try Task.checkCancellation()
            let range = try await source.load(.timeRange)
            guard !range.isEmpty, let target = composition.addMutableTrack(withMediaType: source.mediaType,
                                                                           preferredTrackID: source.trackID) else {
                throw ToolError.invalid("A retained stream cannot be copied into the selected container.")
            }
            try target.insertTimeRange(range, of: source, at: range.start)
            target.isEnabled = try await source.load(.isEnabled)
            target.languageCode = try await source.load(.languageCode)
            target.extendedLanguageTag = try await source.load(.extendedLanguageTag)
            if source.mediaType == .video {
                target.preferredTransform = try await source.load(.preferredTransform)
            }
            targets[source.trackID] = target
        }
        for source in retained {
            try Task.checkCancellation()
            guard let target = targets[source.trackID] else { continue }
            for type in try await source.load(.availableTrackAssociationTypes) {
                for associated in try await source.loadAssociatedTracks(ofType: type) {
                    if let retainedAssociation = targets[associated.trackID] {
                        target.addTrackAssociation(to: retainedAssociation, type: type)
                    }
                }
            }
        }

        let preset = AVAssetExportPresetPassthrough
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: composition, outputFileType: format.fileType),
              let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ToolError.invalid("These streams cannot be copied into \(format.rawValue.uppercased()). Choose another compatible container.")
        }
        try Task.checkCancellation()
        return Prepared(asset: asset, session: session, retained: retained, removedCount: selected.count)
    }

    private struct StreamSignature: Hashable {
        let type: AVMediaType
        let codecs: Set<FourCharCode>
    }

    private static func signatures(for tracks: [AVAssetTrack]) async throws -> [StreamSignature: Int] {
        var counts: [StreamSignature: Int] = [:]
        for track in tracks {
            try Task.checkCancellation()
            let formats = try await track.load(.formatDescriptions)
            let codecIDs = Set(formats.map { CMFormatDescriptionGetMediaSubType($0) })
            counts[StreamSignature(type: track.mediaType, codecs: codecIDs), default: 0] += 1
        }
        return counts
    }

    private static func format(for input: URL, options: MuteVideoOptions) throws -> Format {
        switch options.container {
        case .movie: return .mov
        case .mp4: return .mp4
        case .original:
            guard let format = Format(rawValue: input.pathExtension.lowercased()) else {
                throw ToolError.invalid("The original container cannot be written by the video copy engine. Choose MOV or MP4.")
            }
            return format
        }
    }

    private static func localAsset(_ input: URL) throws -> AVURLAsset {
        guard input.isFileURL, try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("Choose a readable local video.")
        }
        return AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
    }

    private static func mediaName(_ media: AVMediaType) -> String {
        switch media {
        case .audio: "Audio"
        case .video: "Video"
        case .text, .subtitle: "Subtitles"
        case .closedCaption: "Closed captions"
        case .timecode: "Timecode"
        case .metadata: "Metadata"
        default: media.rawValue
        }
    }

    private static func codecName(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4a", "aac": return "AAC"
        default: return name
        }
    }
}
