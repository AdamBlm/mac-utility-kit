import AudioToolbox
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

    public var automaticallyAdjustsSettings = false
    public var format = AudioOutputFormat.m4a
    public var channels = Channels.source
    public var sampleRate: Int?
    public var bitrate = 128
    public var losslessCompression = 5
    public var preservesMetadata = true
    public var ffmpegExecutable: URL?

    public init() {}

    public static var recommended: Self {
        var options = Self()
        options.automaticallyAdjustsSettings = true
        return options
    }

    public static let sampleRates = [32_000, 44_100, 48_000, 88_200, 96_000]
    public static let bitrates = [64, 96, 128, 160, 192, 224, 256, 320]
    // LAME's constant-bitrate choices vary by MPEG version.
    private static let mp3Profiles: [(rates: [Int], bitrates: [Int])] = [
        ([8_000, 11_025, 12_000], [8, 16, 24, 32, 40, 48, 56, 64]),
        ([16_000, 22_050, 24_000], [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]),
        ([32_000, 44_100, 48_000], [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320])
    ]

    public var isLossy: Bool { format == .m4a || format == .mp3 }
    public var supportsMetadata: Bool { format == .m4a || format == .mp3 || format == .flac }

    public var supportedRates: [Int] {
        format == .mp3 ? Self.mp3Profiles.flatMap(\.rates) : Self.sampleRates
    }

    public var supportedBitrates: [Int] { supportedBitrates(at: sampleRate) }

    private func supportedBitrates(at rate: Int?) -> [Int] {
        guard format == .mp3 else { return Self.bitrates }
        if let rate { return Self.mp3Profiles.first(where: { $0.rates.contains(rate) })?.bitrates ?? [] }
        return Set(Self.mp3Profiles.flatMap(\.bitrates)).sorted()
    }

    public var validationIssue: String? {
        if !automaticallyAdjustsSettings, let sampleRate, !supportedRates.contains(sampleRate) {
            return "The format does not support this sample rate."
        }
        if !automaticallyAdjustsSettings && isLossy && !supportedBitrates.contains(bitrate) {
            return "Choose a bitrate supported by the selected sample rate."
        }
        if format == .flac && !(0...8).contains(losslessCompression) {
            return "Choose a FLAC compression level from 0 to 8."
        }
        if format.requiresFFmpeg, ffmpegExecutable.map(ExternalTool.isExecutable) != true {
            return "Choose an FFmpeg executable for \(format.title) output."
        }
        return nil
    }

    package func sourceIssue(_ source: AudioConvert.SourceFormat) -> String? {
        let settings = resolved(for: source)
        let outputChannels = settings.channels.count ?? source.channels
        if !format.requiresFFmpeg, outputChannels > 2 {
            return "Choose Mono or Stereo for this multichannel input."
        }
        return settings.mp3Issue(rate: settings.sampleRate ?? source.sampleRate, channels: outputChannels)
    }

    package func automaticAdjustment(for source: AudioConvert.SourceFormat) -> String? {
        guard automaticallyAdjustsSettings else { return nil }
        let settings = resolved(for: source)
        var changes: [String] = []
        if let rate = settings.sampleRate {
            let original = (Double(source.sampleRate) / 1000).formatted()
            let chosen = (Double(rate) / 1000).formatted()
            changes.append("\(original) → \(chosen) kHz")
        }
        if settings.channels == .stereo {
            changes.append("\(source.channels) channels → stereo")
        }
        if settings.bitrate != Self().bitrate {
            changes.append("\(settings.bitrate) kbps target")
        }
        return changes.isEmpty ? nil : changes.joined(separator: " · ")
    }

    fileprivate func resolved(for source: AudioConvert.SourceFormat?) -> Self {
        guard automaticallyAdjustsSettings else { return self }
        var settings = self
        settings.sampleRate = nil
        settings.channels = .source
        settings.bitrate = Self().bitrate
        guard let source else { return settings }

        if source.channels > 2, format != .flac {
            settings.channels = .stereo
        }
        if format == .mp3, !supportedRates.contains(source.sampleRate) {
            settings.sampleRate = supportedRates.last(where: { $0 <= source.sampleRate }) ?? supportedRates.first
        }
        if format == .m4a, !Self.aacRates.isEmpty, !Self.aacRates.contains(source.sampleRate) {
            settings.sampleRate = Self.aacRates.last(where: { $0 <= source.sampleRate }) ?? Self.aacRates.first
        }
        if format == .mp3 {
            let available = supportedBitrates(at: settings.sampleRate ?? source.sampleRate)
            if let bitrate = available.last(where: { $0 <= settings.bitrate }) ?? available.first {
                settings.bitrate = bitrate
            }
        }
        if format == .m4a {
            let rate = settings.sampleRate ?? source.sampleRate
            let channels = settings.channels.count ?? source.channels
            let available = Self.aacBitrates(rate: rate, channels: channels)
            if let bitrate = available.last(where: { $0 <= settings.bitrate }) ?? available.first {
                settings.bitrate = bitrate
            }
        }
        return settings
    }

    private static func aacBitrates(rate: Int, channels: Int) -> [Int] {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)),
              let aac = AVAudioFormat(settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels
              ]),
              let converter = AVAudioConverter(from: pcm, to: aac) else { return [] }
        converter.bitRateStrategy = AVAudioBitRateStrategy_Constant
        return (converter.applicableEncodeBitRates ?? []).map { $0.intValue / 1_000 }.sorted()
    }

    private static let aacRates: [Int] = {
        var format = kAudioFormatMPEG4AAC
        let formatSize = UInt32(MemoryLayout.size(ofValue: format))
        let property = kAudioFormatProperty_AvailableEncodeSampleRates
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, formatSize, &format, &size) == noErr else { return [] }
        var ranges = [AudioValueRange](repeating: .init(), count: Int(size) / MemoryLayout<AudioValueRange>.stride)
        let status = ranges.withUnsafeMutableBufferPointer {
            AudioFormatGetProperty(property, formatSize, &format, &size, $0.baseAddress)
        }
        guard status == noErr else { return [] }
        return ranges.compactMap {
            return $0.mMinimum == $0.mMaximum ? Int(exactly: $0.mMaximum) : nil
        }.sorted()
    }()

    func mp3Issue(rate: Int?, channels: Int?) -> String? {
        guard format == .mp3 else { return nil }
        if let rate, !supportedRates.contains(rate) {
            return "MP3 cannot keep the input sample rate. Choose a supported sample rate."
        }
        if !supportedBitrates(at: rate).contains(bitrate) {
            return "MP3 cannot use this bitrate at the source sample rate. Choose a compatible bitrate or set the output sample rate explicitly."
        }
        if let channels, channels > 2 {
            return "MP3 supports mono or stereo. Choose a channel layout for this multichannel input."
        }
        return nil
    }
}

public enum AudioConvert {
    package struct SourceFormat: Sendable {
        package let sampleRate: Int
        package let channels: Int
    }

    package static func sourceFormat(_ input: URL) -> SourceFormat? {
        guard let resolved = LocalInputFile.regularFile(input),
              let file = try? AVAudioFile(forReading: resolved) else { return nil }
        let rate = file.fileFormat.sampleRate.rounded()
        guard rate.isFinite, rate > 0, rate < Double(Int.max) else { return nil }
        return SourceFormat(sampleRate: Int(rate), channels: Int(file.fileFormat.channelCount))
    }

    public static func export(
        _ input: URL, to output: URL, options: AudioConvertOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        if let issue = options.validationIssue { throw ToolError.invalid(issue) }
        let manager = FileManager.default
        let version = try LocalInputFile.Version.read(input)
        let resolved = version.resolved
        guard LocalInputFile.isLocalURL(output), resolved != output.resolvingSymlinksInPath().standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a local audio source and a new output file.")
        }
        let source = sourceFormat(resolved)
        if let source, let issue = options.sourceIssue(source) { throw ToolError.invalid(issue) }
        let options = options.resolved(for: source)
        let expectedRate = options.sampleRate ?? source?.sampleRate
        let expectedChannels = options.channels.count ?? source?.channels
        let staging = output.deletingLastPathComponent().appending(path: ".audio-convert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Converted." + options.format.rawValue)
        if options.format.requiresFFmpeg {
            try await FFmpegAudioConvert.export(resolved, to: candidate, options: options, mp3Rate: expectedRate)
        } else {
            let asset = AVURLAsset(url: resolved, options: [
                AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ToolError.invalid("The input has no readable audio track.")
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
        guard file.length > 0,
              expectedRate == nil || expectedRate == rate,
              expectedChannels == nil || expectedChannels == channels,
              verify(codec, format: options.format) else {
            throw ToolError.invalid("The converted file did not match the selected codec, sample rate, or channel count.")
        }
        if let issue = options.mp3Issue(rate: rate, channels: channels) { throw ToolError.invalid(issue) }
        guard let probe = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512) else {
            throw ToolError.invalid("Could not verify playback of the converted audio.")
        }
        try file.read(into: probe)
        guard probe.frameLength > 0 else {
            throw ToolError.invalid("The converted file has no playable audio samples.")
        }
        try Task.checkCancellation()
        guard (try? LocalInputFile.Version.read(input)) == version else {
            throw ToolError.invalid("The source audio changed during conversion. Try again.")
        }
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        let khz = (Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...3)))
        let target = options.automaticallyAdjustsSettings && options.isLossy ? " · \(options.bitrate) kbps target" : ""
        return "\(input.lastPathComponent) · \(options.format.title) · \(khz) kHz · \(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels")" + target
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
