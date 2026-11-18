import AVFoundation

public enum AudioTrim {
    private static let chunkSize: AVAudioFrameCount = 16_384

    public static func source(_ input: URL) throws -> AudioTrimSource {
        try describe(open(input), input: input)
    }

    public static func waveform(_ input: URL, bins: Int = 400) async throws -> AudioTrimWaveform {
        let file = try open(input)
        let source = try describe(file, input: input)
        let binCount = Int(min(Int64(max(1, min(bins, 2048))), source.frameCount))
        var peaks = [Float](repeating: 0, count: binCount)
        let buffer = try makeBuffer(for: file)
        let channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData else { throw ToolError.invalid("Could not read waveform samples.") }
        let framesPerBin = Double(source.frameCount) / Double(binCount)
        var position: Int64 = 0
        while position < source.frameCount {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunkSize), source.frameCount - position)))
            if buffer.frameLength == 0 { break }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(binCount - 1, Int(Double(position + Int64(frame)) / framesPerBin))
                for channel in 0..<channels {
                    let sample = abs(data[channel][frame])
                    if sample.isFinite { peaks[bin] = max(peaks[bin], sample) }
                }
            }
            position += Int64(buffer.frameLength)
            await Task.yield()
        }
        guard position > 0 else { throw ToolError.invalid("No audio samples were decoded.") }
        return AudioTrimWaveform(source: source, peaks: peaks)
    }

    public static func export(
        _ input: URL, to output: URL, options: AudioTrimOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let manager = FileManager.default
        guard output.isFileURL, output.standardizedFileURL != input.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let read = try open(input)
        let info = try describe(read, input: input)
        let selection = try AudioTrimSelection.plan(info, options: options)
        try Task.checkCancellation()
        let staging = output.deletingLastPathComponent().appending(path: ".audio-trim-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Trimmed.\(options.format.rawValue)")
        if options.mode == .lossless {
            let pcm = read.fileFormat
            let actual = pcm.streamDescription.pointee
            let common: AVAudioCommonFormat
            if actual.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                common = actual.mBitsPerChannel > 32 ? .pcmFormatFloat64 : .pcmFormatFloat32
            } else {
                common = .pcmFormatInt32
            }
            let exact = try open(input, commonFormat: common)
            try await write(exact, to: candidate, settings: pcm.settings, selection: selection,
                            usesFades: false, progress: progress)
            let outputFormat = try open(candidate).fileFormat
            let result = outputFormat.streamDescription.pointee
            guard result.mFormatID == actual.mFormatID, result.mBitsPerChannel == actual.mBitsPerChannel,
                  result.mFormatFlags & kAudioFormatFlagIsFloat == actual.mFormatFlags & kAudioFormatFlagIsFloat else {
                throw ToolError.invalid("Could not retain the original PCM sample format.")
            }
        } else {
            try await write(read, to: candidate, settings: settings(for: read.processingFormat, as: options.format),
                            selection: selection, usesFades: true, progress: progress)
        }

        let result = try open(candidate)
        let tolerance = options.format == .m4a ? Int64((info.sampleRate * 0.05).rounded(.up)) : 0
        guard abs(result.length - selection.frameCount) <= tolerance,
              result.processingFormat.sampleRate == info.sampleRate,
              result.processingFormat.channelCount == read.processingFormat.channelCount else {
            throw ToolError.invalid("The output audio did not match the expected duration or sample format.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        let duration = (Double(selection.frameCount) / info.sampleRate).formatted(.number.precision(.fractionLength(0...3)))
        return "\(input.lastPathComponent) · \(duration) s · \(options.format.title)"
    }

    private static func open(_ url: URL, commonFormat: AVAudioCommonFormat = .pcmFormatFloat32) throws -> AVAudioFile {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("Choose a readable local audio file.")
        }
        return try AVAudioFile(forReading: url, commonFormat: commonFormat, interleaved: false)
    }

    private static func describe(_ file: AVAudioFile, input: URL) throws -> AudioTrimSource {
        let rate = file.processingFormat.sampleRate
        let frames = file.length
        guard rate.isFinite, rate > 0, frames > 0 else {
            throw ToolError.invalid("Could not read the sample rate or audio duration.")
        }
        let format = file.fileFormat.streamDescription.pointee
        let lossless = format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel <= 64
            ? AudioTrimFormat.pcmContainer(for: input) : nil
        return AudioTrimSource(sampleRate: rate, frameCount: frames, losslessFormat: lossless)
    }

    private static func makeBuffer(for file: AVAudioFile) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else {
            throw ToolError.invalid("Could not allocate audio buffers.")
        }
        return buffer
    }

    private static func settings(for source: AVAudioFormat, as format: AudioTrimFormat) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: source.channelCount
        ]
        if format == .m4a {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        return settings
    }

    private static func write(
        _ input: AVAudioFile, to output: URL, settings: [String: Any], selection: AudioTrimSelection,
        usesFades: Bool, progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let file = try AVAudioFile(forWriting: output, settings: settings,
                                   commonFormat: input.processingFormat.commonFormat, interleaved: false)
        let buffer = try makeBuffer(for: input)
        input.framePosition = selection.firstFrame
        var written: Int64 = 0
        while written < selection.frameCount {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(Int64(chunkSize), selection.frameCount - written))
            try input.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { throw ToolError.invalid("The audio ended before the selected out point.") }
            if usesFades { applyFades(to: buffer, startingAt: written, selection: selection) }
            try file.write(from: buffer)
            written += Int64(buffer.frameLength)
            await progress(0.99 * Double(written) / Double(selection.frameCount))
        }
    }

    private static func applyFades(to buffer: AVAudioPCMBuffer, startingAt start: Int64, selection: AudioTrimSelection) {
        guard let channels = buffer.floatChannelData else { return }
        let frameLength = Int64(buffer.frameLength)
        let fadeOutStart = selection.frameCount - selection.fadeOutFrames
        if start >= selection.fadeInFrames, start + frameLength <= fadeOutStart { return }
        for frame in 0..<Int(frameLength) {
            let position = start + Int64(frame)
            var gain: Float = 1
            if position < selection.fadeInFrames {
                gain = Float(position) / Float(max(1, selection.fadeInFrames - 1))
            }
            if position >= fadeOutStart {
                gain = Float(selection.frameCount - 1 - position) / Float(max(1, selection.fadeOutFrames - 1))
            }
            if gain != 1 {
                for channel in 0..<Int(buffer.format.channelCount) { channels[channel][frame] *= gain }
            }
        }
    }
}
