import AVFoundation
import Foundation

public struct AudioConvertOptions: Equatable, Sendable {
    public enum Channels: String, CaseIterable, Identifiable, Sendable {
        case source = "Same as input"
        case mono = "Mono"
        case stereo = "Stereo"
        public var id: Self { self }

        var count: Int? {
            switch self {
            case .source: nil
            case .mono: 1
            case .stereo: 2
            }
        }
    }

    public var format = AudioOutputFormat.m4a
    public var channels = Channels.source
    public var sampleRate: Int?
    public var bitrate = 128
    public var losslessCompression = 5
    public var preservesMetadata = true
    public var ffmpegExecutable: URL?

    public init() {}

    public static let sampleRates = [32_000, 44_100, 48_000, 88_200, 96_000]
    public static let bitrates = [64, 96, 128, 160, 192, 224, 256, 320]

    public var isLossy: Bool { format == .m4a || format == .mp3 }
    public var supportsMetadata: Bool { format == .m4a || format == .mp3 || format == .flac }

    public var supportedRates: [Int] {
        format == .mp3 ? [32_000, 44_100, 48_000] : Self.sampleRates
    }

    public var validationIssue: String? {
        if let sampleRate, !supportedRates.contains(sampleRate) {
            return "The format does not support this sample rate."
        }
        if isLossy && !Self.bitrates.contains(bitrate) {
            return "Choose an audio bitrate from the list."
        }
        if format == .flac && !(0...8).contains(losslessCompression) {
            return "Choose a FLAC compression level from 0 to 8."
        }
        if format.requiresFFmpeg, ffmpegExecutable.map(ExternalTool.isExecutable) != true {
            return "Choose an FFmpeg executable for \(format.title) output."
        }
        return nil
    }
}

public enum AudioConvert {
    public static func export(
        _ input: URL, to output: URL, options: AudioConvertOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        if let issue = options.validationIssue { throw ToolError.invalid(issue) }
        let manager = FileManager.default
        guard input.isFileURL, try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a local audio source and a new output file.")
        }
        let staging = output.deletingLastPathComponent().appending(path: ".audio-convert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Converted." + options.format.rawValue)
        let inputFormat = try? AVAudioFile(forReading: input).fileFormat
        let originalRate = inputFormat.map { Int($0.sampleRate.rounded()) }
        let originalChannels = inputFormat.map { Int($0.channelCount) }
        if options.format.requiresFFmpeg {
            try await FFmpegAudioConvert.export(input, to: candidate, options: options)
        } else {
            let asset = AVURLAsset(url: input, options: [
                AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ToolError.invalid("The input has no readable audio track.")
            }
            if options.channels == .source, let originalChannels, originalChannels > 2 {
                throw ToolError.invalid("Choose Mono or Stereo for this multichannel input.")
            }
            var extraction = AudioExtractionOptions()
            extraction.format = options.format
            let encoding = NativeAudioEncodingSettings(sampleRate: options.sampleRate.map(Double.init), channels: options.channels.count,
                                                       bitrate: options.isLossy ? options.bitrate * 1_000 : nil, preservesMetadata: options.preservesMetadata)
            try await AVFoundationAudioExtraction.export(asset, track: track, to: candidate,
                                                        options: extraction, preview: false, encoding: encoding) { fraction in
                await progress(min(0.99, fraction))
            }
        }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: candidate)
        let outputFormat = file.fileFormat
        let rate = Int(outputFormat.sampleRate.rounded())
        let channels = Int(outputFormat.channelCount)
        let codec = withExtendedLifetime(outputFormat) { outputFormat.streamDescription.pointee.mFormatID }
        let expectedRate = options.sampleRate ?? originalRate
        let expectedChannels = options.channels.count ?? originalChannels
        guard file.length > 0,
              expectedRate == nil || expectedRate == rate,
              expectedChannels == nil || expectedChannels == channels,
              verify(codec, format: options.format) else {
            throw ToolError.invalid("The converted file did not match the selected codec, sample rate, or channel count.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        let khz = (Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...3)))
        return "\(input.lastPathComponent) · \(options.format.title) · \(khz) kHz · \(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels")"
    }

    private static func verify(_ codec: AudioFormatID, format: AudioOutputFormat) -> Bool {
        switch format {
        case .m4a: codec == kAudioFormatMPEG4AAC
        case .mp3: codec == kAudioFormatMPEGLayer3
        case .flac: codec == kAudioFormatFLAC
        case .wav, .aiff: codec == kAudioFormatLinearPCM
        }
    }
}
