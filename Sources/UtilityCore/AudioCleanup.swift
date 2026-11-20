import AVFoundation

public enum AudioCleanup {
    public static func duration(_ input: URL) async throws -> Double {
        guard input.isFileURL else { throw ToolError.invalid("Choose a local audio or video file.") }
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else {
            throw ToolError.invalid("Could not read the media duration.")
        }
        return seconds
    }

    public static func preview(
        _ input: URL, options: AudioCleanupOptions, start: Double, duration: Double
    ) async throws -> AudioCleanupPreview {
        let executable = try validate(input, options: options)
        guard start.isFinite, start >= 0, duration.isFinite, (0.1...12).contains(duration) else {
            throw ToolError.invalid("Choose a preview segment from 0.1 to 12 seconds.")
        }
        let manager = FileManager.default
        let staging = try makeStaging(in: manager.temporaryDirectory)
        defer { try? manager.removeItem(at: staging) }
        let dry = staging.appending(path: "original.wav")
        let wet = staging.appending(path: "cleaned.wav")
        let report = staging.appending(path: "audio-levels.txt")
        try Data().write(to: report)
        let levelOutput = try FileHandle(forWritingTo: report)
        defer { try? levelOutput.close() }
        let segment = decimal(duration)
        let selection = ["-map", "0:a:\(options.trackIndex)", "-t", segment, "-ar", "48000",
                         "-ac", "2", "-c:a", "pcm_f32le", "-f", "wav"]
        var arguments = prefix
        arguments.append(contentsOf: ["-ss", decimal(start), "-i", input.path])
        arguments.append(contentsOf: selection)
        arguments.append(dry.path)
        arguments.append(contentsOf: selection)
        // Measure the selected segment before stereo playback conversion can hide a channel peak.
        let wetFilters = [filter(options), "atrim=duration=\(segment)", peakFilter].joined(separator: ",")
        arguments.append(contentsOf: ["-af", wetFilters, wet.path])
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments, directory: staging,
                                   standardOutput: levelOutput)
        let sourcePeak = try readPeak(report)
        let dryLevel = try measure(dry)
        let wetLevel = try measure(wet)
        guard dryLevel.rms > 0.000_01 else {
            throw ToolError.invalid("This segment contains no audible audio. Try a different start time.")
        }
        let target = min(dryLevel.rms, wetLevel.rms, 0.1259)
        let match = wetLevel.rms > 0.000_01
        let dryGain = match ? Float(target / dryLevel.rms) : 1
        let wetGain = match ? Float(target / wetLevel.rms) : 1
        try Task.checkCancellation()
        return AudioCleanupPreview(original: try Data(contentsOf: dry), cleaned: try Data(contentsOf: wet),
                                   originalVolume: dryGain, cleanedVolume: wetGain,
                                   isNearClipping: sourcePeak >= nearClippingDB || wetLevel.peak >= 0.99,
                                   duration: min(dryLevel.duration, wetLevel.duration))
    }

    public static func export(
        _ input: URL, to output: URL, options: AudioCleanupOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let executable = try validate(input, options: options)
        let manager = FileManager.default
        guard output.isFileURL, output.standardizedFileURL != input.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let staging = try makeStaging(in: output.deletingLastPathComponent())
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Cleaned.\(options.output.rawValue)")
        let report = staging.appending(path: "audio-levels.txt")
        try Data().write(to: report)
        let levelOutput = try FileHandle(forWritingTo: report)
        defer { try? levelOutput.close() }

        var arguments = prefix + ["-copyts", "-start_at_zero", "-i", input.path]
        if options.output == .mkv { arguments += ["-map", "0:V:0", "-c:v", "copy"] }
        arguments += ["-map", "0:a:\(options.trackIndex)", "-af", [filter(options), peakFilter].joined(separator: ","),
                      "-c:a", options.output == .wav ? "pcm_f32le" : "flac",
                      "-f", options.output == .wav ? "wav" : "matroska", candidate.path]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments, directory: staging, standardOutput: levelOutput)
        let peak = try readPeak(report)
        guard peak > -100 else { throw ToolError.invalid("The selected audio track is silent after filtering.") }
        if options.output == .mkv {
            try await ExternalTool.run(executable, name: "FFmpeg",
                                       arguments: prefix + ["-xerror", "-i", candidate.path, "-map", "0:V:0", "-frames:v", "1", "-f", "null", "-"],
                                       directory: staging)
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        let warning = peak >= nearClippingDB ? " · Peaks near clipping" : ""
        return "\(input.lastPathComponent) · \(options.output.title)\(warning)"
    }

    private static let prefix = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-protocol_whitelist", "file"]
    private static let nearClippingDB = -0.1
    private static let peakFilter = "astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=Peak_level,"
        + "ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-:direct=1"

    private static func validate(_ input: URL, options: AudioCleanupOptions) throws -> URL {
        guard input.isFileURL, try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("Choose a readable local audio or video file.")
        }
        if let issue = options.validationIssue { throw ToolError.invalid(issue) }
        guard let executable = options.executable else { throw ToolError.invalid("Choose an FFmpeg executable.") }
        return executable
    }

    private static func filter(_ options: AudioCleanupOptions) -> String {
        var filters: [String] = []
        if options.hum != .off {
            filters += (1...4).map { "bandreject=f=\(options.hum.rawValue * $0):width_type=q:width=12" }
        }
        if options.reductionDB > 0 {
            let floor = options.profile == .speech ? -45 : -60
            let smoothing = options.profile == .speech ? 4 : 2
            let amount = decimal(max(0.01, options.reductionDB))
            filters.append("afftdn=nr=\(amount):nf=\(floor):gs=\(smoothing)")
        }
        return filters.isEmpty ? "anull" : filters.joined(separator: ",")
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func makeStaging(in directory: URL) throws -> URL {
        let staging = directory.appending(path: ".audio-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    private static func readPeak(_ url: URL) throws -> Double {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        try file.seek(toOffset: length > 4096 ? length - 4096 : 0)
        let tail = String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
        let key = "lavfi.astats.Overall.Peak_level="
        guard let last = tail.split(whereSeparator: \.isNewline).reversed().first(where: { $0.hasPrefix(key) }),
              let peak = Double(last.dropFirst(key.count)) else {
            throw ToolError.invalid("No decoded audio was found on the selected track.")
        }
        return peak
    }

    private struct Level {
        let peak: Double
        let rms: Double
        let duration: Double
    }

    private static func measure(_ url: URL) throws -> Level {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let channels = buffer.floatChannelData else {
            throw ToolError.invalid("Could not measure this preview segment.")
        }
        var peak = 0.0
        var sum = 0.0
        var samples = 0
        let channelCount = Int(buffer.format.channelCount)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            for channel in 0..<channelCount {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = abs(Double(channels[channel][frame]))
                    if sample.isFinite {
                        peak = max(peak, sample)
                        sum += sample * sample
                    }
                }
            }
            samples += Int(buffer.frameLength) * channelCount
        }
        guard samples > 0 else { throw ToolError.invalid("The preview does not contain audio samples.") }
        let duration = Double(file.framePosition) / file.processingFormat.sampleRate
        return Level(peak: peak, rms: sqrt(sum / Double(samples)), duration: duration)
    }
}
