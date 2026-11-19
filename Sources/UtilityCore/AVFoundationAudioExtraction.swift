import AVFoundation

struct NativeAudioEncodingSettings {
    var sampleRate: Double?
    var channels: Int?
    var bitrate: Int?
    var preservesMetadata = false
}

enum AVFoundationAudioExtraction {
    static func export(
        _ asset: AVURLAsset, track: AVAssetTrack, to output: URL, options: AudioExtractionOptions,
        preview: Bool, encoding: NativeAudioEncodingSettings = .init(),
        progress: @Sendable (Double) async -> Void
    ) async throws {
        let format = try await track.load(.formatDescriptions).first
        let source = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = encoding.channels ?? Int(source?.mChannelsPerFrame ?? 2)
        let sampleRate = encoding.sampleRate ?? source?.mSampleRate ?? 48_000
        guard channels > 0, sampleRate.isFinite, sampleRate > 0 else {
            throw ToolError.invalid("Could not read the audio channel count or sample rate.")
        }

        let type: AVFileType
        let settings: [String: Any]?
        switch options.format {
        case .m4a:
            type = .m4a
            settings = options.passthrough ? nil : [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: encoding.bitrate ?? options.quality.bitrate
            ]
        case .wav, .aiff:
            type = options.format == .wav ? .wav : .aiff
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsBigEndianKey: options.format == .aiff, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .mp3, .flac:
            throw ToolError.invalid("Choose an FFmpeg executable for this format.")
        }

        let sourceRange = try await track.load(.timeRange)
        let duration = preview ? min(sourceRange.duration, CMTime(seconds: 5, preferredTimescale: 600)) : sourceRange.duration
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            throw ToolError.invalid("Could not read the audio duration.")
        }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: type)
        if encoding.preservesMetadata, type == .m4a {
            var converted: [AVMetadataItem] = []
            for item in try await asset.load(.commonMetadata) {
                try Task.checkCancellation()
                guard let key = item.commonKey, let value = try await item.load(.value) else { continue }
                let tag = AVMutableMetadataItem()
                tag.identifier = AVMetadataIdentifier(rawValue: "common/" + key.rawValue)
                tag.value = value
                converted.append(tag)
            }
            writer.metadata = converted
        }
        let sourceSettings: [String: Any]? = options.passthrough ? nil : [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: sourceSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw ToolError.invalid("The selected format cannot encode this audio track.")
        }
        let trackInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings,
                                           sourceFormatHint: options.passthrough ? format : nil)
        if type == .m4a {
            trackInput.languageCode = try await track.load(.languageCode)
            trackInput.extendedLanguageTag = try await track.load(.extendedLanguageTag)
        }
        guard reader.canAdd(trackOutput), writer.canAdd(trackInput) else {
            throw ToolError.invalid("The selected format cannot write this audio track.")
        }
        reader.add(trackOutput)
        writer.add(trackInput)
        reader.timeRange = CMTimeRange(start: sourceRange.start, duration: duration)
        guard writer.startWriting() else {
            throw writer.error ?? ToolError.invalid("Could not start writing audio.")
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard reader.startReading() else {
            throw reader.error ?? ToolError.invalid("Could not start reading audio.")
        }
        writer.startSession(atSourceTime: sourceRange.start)
        try await transfer(trackOutput, to: trackInput, reader: reader, writer: writer,
                           range: reader.timeRange, progress: progress)
        if preview { writer.endSession(atSourceTime: sourceRange.start + duration) }
        await writer.finishMediaWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? ToolError.invalid("Could not finish writing audio.")
        }
    }

    private static func transfer(
        _ output: AVAssetReaderTrackOutput, to input: AVAssetWriterInput,
        reader: AVAssetReader, writer: AVAssetWriter, range: CMTimeRange,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        let samples = AsyncAssetReaderSamples(reader: reader, output: output)
        var wroteSample = false
        var lastProgress = 0.0
        while true {
            try Task.checkCancellation()
            if let error = reader.error ?? writer.error { throw error }
            if !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(4))
                continue
            }
            guard let buffer = try await samples.next() else { break }
            guard input.append(buffer) else {
                throw writer.error ?? ToolError.invalid("Could not write an audio sample.")
            }
            wroteSample = true
            let fraction = min(1, (buffer.presentationTimeStamp - range.start).seconds / range.duration.seconds)
            if fraction >= lastProgress + 0.01 {
                lastProgress = fraction
                await progress(fraction)
            }
        }
        if let error = reader.error { throw error }
        guard wroteSample else { throw ToolError.invalid("The selected audio track is empty.") }
        input.markAsFinished()
    }
}
