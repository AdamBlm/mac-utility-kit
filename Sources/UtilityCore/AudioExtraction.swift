import AVFoundation
import Foundation

public enum AudioOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a, wav, aiff, mp3, flac

    public var id: Self { self }
    public var title: String { rawValue.uppercased() }
    public var requiresFFmpeg: Bool { self == .mp3 || self == .flac }
    public var supportsPassthrough: Bool { self == .m4a }
}

public enum AudioExtractionQuality: String, CaseIterable, Identifiable, Sendable {
    case compact, standard, high

    public var id: Self { self }
    public var title: String { rawValue.capitalized }

    var bitrate: Int {
        switch self {
        case .compact: 96_000
        case .standard: 192_000
        case .high: 320_000
        }
    }
}

public struct AudioExtractionOptions: Sendable {
    public var trackIndex = 0
    public var format: AudioOutputFormat = .m4a
    public var quality: AudioExtractionQuality = .standard
    public var passthrough = false
    public var ffmpegExecutable: URL?

    public init() {}
}

public struct AudioExtractionTrack: Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let language: String?
    public let codec: String
    public let channels: Int?

    public var title: String {
        var parts = ["Track \(index + 1)"]
        if let language { parts.append(language) }
        parts.append(codec)
        if let channels { parts.append(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels") }
        return parts.joined(separator: " · ")
    }
}

public enum AudioExtraction {
    public static func trackList(_ input: URL) async throws -> [AudioExtractionTrack] {
        let tracks = try await AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ]).loadTracks(withMediaType: .audio)
        var results: [AudioExtractionTrack] = []
        for (index, track) in tracks.enumerated() {
            results.append(try await describe(track, index: index))
        }
        return results
    }

    public static func preview(_ input: URL, to output: URL, options: AudioExtractionOptions) async throws {
        var sample = options
        sample.format = .m4a
        sample.passthrough = false
        _ = try await export(input, to: output, options: sample, preview: true) { _ in }
    }

    public static func extract(
        _ input: URL, to output: URL, options: AudioExtractionOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        try await export(input, to: output, options: options, preview: false, progress: progress)
    }

    private static func export(
        _ input: URL, to output: URL, options: AudioExtractionOptions, preview: Bool,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ToolError.invalid("This file has no audio track.") }
        guard tracks.indices.contains(options.trackIndex) else {
            throw ToolError.invalid("Audio track \(options.trackIndex + 1) is not available in this file.")
        }
        let track = tracks[options.trackIndex]
        let description = try await describe(track, index: options.trackIndex)

        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("The audio output file already exists.")
        }
        if options.passthrough {
            let subtype = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
            guard options.format.supportsPassthrough,
                  subtype == kAudioFormatMPEG4AAC || subtype == kAudioFormatAppleLossless else {
                throw ToolError.invalid("\(description.codec) cannot be copied to \(options.format.title). Turn off passthrough to convert the track.")
            }
        }

        do {
            if options.format.requiresFFmpeg {
                guard let executable = options.ffmpegExecutable else {
                    throw ToolError.invalid("Choose an FFmpeg executable to export \(options.format.title).")
                }
                try await exportUsingFFmpeg(
                    asset, track: track, language: description.language,
                    to: output, options: options, executable: executable, progress: progress
                )
            } else {
                try await AVFoundationAudioExtraction.export(
                    asset, track: track, to: output, options: options, preview: preview, progress: progress
                )
            }
            try Task.checkCancellation()
            await progress(1)
            return "\(input.lastPathComponent) • \(description.title) → \(options.format.title)"
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func exportUsingFFmpeg(
        _ asset: AVURLAsset, track: AVAssetTrack, language: String?, to output: URL,
        options: AudioExtractionOptions, executable: URL, progress: @Sendable (Double) async -> Void
    ) async throws {
        let pcm = output.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: pcm) }
        var intermediate = options
        intermediate.format = .wav
        // Stage only the AVFoundation-selected track. FFmpeg may enumerate source tracks differently.
        try await AVFoundationAudioExtraction.export(
            asset, track: track, to: pcm, options: intermediate, preview: false
        ) { fraction in
            await progress(fraction * 0.75)
        }
        try await FFmpegAudioExtraction.export(
            pcm, to: output, options: options, executable: executable, language: language
        )
    }

    private static func describe(_ track: AVAssetTrack, index: Int) async throws -> AudioExtractionTrack {
        let format = try await track.load(.formatDescriptions).first
        let subtype = format.map(CMFormatDescriptionGetMediaSubType)
        let channels = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            .map { Int($0.mChannelsPerFrame) }
        let tag = try await track.load(.extendedLanguageTag)
        let code = try await track.load(.languageCode)
        let language = [tag, code].compactMap { $0 }.first { !$0.isEmpty && $0.lowercased() != "und" }
        let codec: String
        switch subtype {
        case kAudioFormatMPEG4AAC: codec = "AAC"
        case kAudioFormatAppleLossless: codec = "ALAC"
        case kAudioFormatMPEGLayer3: codec = "MP3"
        case kAudioFormatFLAC: codec = "FLAC"
        case kAudioFormatLinearPCM: codec = "PCM"
        case let subtype?:
            let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: subtype >> $0) }
            codec = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Audio"
        default: codec = "Audio"
        }
        return AudioExtractionTrack(index: index, language: language, codec: codec, channels: channels)
    }
}
