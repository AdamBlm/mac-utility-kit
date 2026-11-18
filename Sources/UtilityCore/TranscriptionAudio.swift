import AVFoundation
import Foundation

enum TranscriptionAudio {
    struct Selection {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let range: CMTimeRange
    }

    static func selection(_ input: URL, options: TranscriptionOptions) async throws -> Selection {
        guard input.isFileURL, try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("Choose a readable local audio or video file.")
        }
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        var selected: AVAssetTrack?
        for track in try await asset.loadTracks(withMediaType: .audio) {
            if try await track.load(.isEnabled) {
                selected = track
                break
            }
        }
        guard let track = selected else { throw ToolError.invalid("This media file does not contain an enabled audio track.") }
        let trackRange = try await track.load(.timeRange)
        let duration = try await asset.load(.duration).seconds
        let range = try VideoTrimRange.validate(start: options.start, end: options.end, duration: duration)
        let requested = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 1_000_000),
                                    end: CMTime(seconds: range.end, preferredTimescale: 1_000_000))
        let effective = requested.intersection(trackRange)
        guard effective.duration.seconds.isFinite, effective.duration.seconds > 0 else {
            throw ToolError.invalid("No audio falls inside the selected range.")
        }
        return Selection(asset: asset, track: track, range: effective)
    }

    static func normalize(_ selection: Selection, to output: URL) async throws {
        let reader = try AVAssetReader(asset: selection.asset)
        reader.timeRange = selection.range
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
        ]
        let samples = AVAssetReaderAudioMixOutput(audioTracks: [selection.track], audioSettings: settings)
        samples.alwaysCopiesSampleData = false
        let writer = try AVAssetWriter(outputURL: output, fileType: .wav)
        let sink = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard reader.canAdd(samples), writer.canAdd(sink) else {
            throw ToolError.invalid("Could not configure local audio conversion.")
        }
        reader.add(samples)
        writer.add(sink)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? ToolError.invalid("Could not start local audio conversion.")
        }
        writer.startSession(atSourceTime: selection.range.start)
        let buffers = AsyncAssetReaderSamples(reader: reader, output: samples)
        var wroteAudio = false
        while true {
            try Task.checkCancellation()
            if let error = reader.error ?? writer.error { throw error }
            if !sink.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            guard let sample = try await buffers.next() else { break }
            guard sink.append(sample) else {
                throw writer.error ?? ToolError.invalid("Could not normalize an audio sample.")
            }
            wroteAudio = true
        }
        if let error = reader.error { throw error }
        guard wroteAudio else { throw ToolError.invalid("No audio frames were found in the selected range.") }
        sink.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? ToolError.invalid("Could not finish local audio conversion.")
        }
        let file = try AVAudioFile(forReading: output)
        guard file.fileFormat.sampleRate == 16_000, file.fileFormat.channelCount == 1, file.length > 0 else {
            throw ToolError.invalid("The normalized WAV was not 16 kHz mono audio.")
        }
    }
}
