import AVFoundation
import Foundation

public struct AudioMergeOptions: Equatable, Sendable {
    public enum Transition: String, CaseIterable, Identifiable, Sendable {
        case cut = "Straight cut"
        case gap = "Silence"
        case crossfade = "Crossfade"

        public var id: Self { self }
    }

    public var transition = Transition.cut
    public var transitionMilliseconds = 500
    public var format = AudioOutputFormat.m4a
    public var sampleRate = 48_000
    public var stereo = true
    public var ffmpegExecutable: URL?

    public init() {}

    public var validationIssue: String? {
        if ![44_100, 48_000].contains(sampleRate) { return "Choose 44.1 or 48 kHz output." }
        if transition != .cut && !(10...10_000).contains(transitionMilliseconds) {
            return "Enter a transition from 10 to 10,000 milliseconds."
        }
        if ffmpegExecutable.map(ExternalTool.isExecutable) != true {
            return "Choose an FFmpeg executable to merge audio."
        }
        return nil
    }
}

public enum AudioMerge {
    public static func export(
        _ inputs: [URL], to output: URL, options: AudioMergeOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        if let issue = options.validationIssue { throw ToolError.invalid(issue) }
        guard (2...100).contains(inputs.count), let executable = options.ffmpegExecutable else {
            throw ToolError.invalid("Choose 2 to 100 audio files to merge.")
        }
        let manager = FileManager.default
        guard output.isFileURL, !manager.fileExists(atPath: output.path),
              output.pathExtension.lowercased() == options.format.rawValue else {
            throw ToolError.invalid("Choose a new local output with the selected audio format.")
        }
        var durations: [Double] = []
        for (index, url) in inputs.enumerated() {
            try Task.checkCancellation()
            guard url.isFileURL, url.standardizedFileURL != output.standardizedFileURL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw ToolError.invalid("Choose a readable audio file for clip \(index + 1).")
            }
            let duration = (try? AudioTrim.source(url)).map { Double($0.frameCount) / $0.sampleRate }
            if options.transition == .crossfade {
                let fades = (index == 0 || index == inputs.count - 1) ? 1 : 2
                let requiredDuration = Double(fades * options.transitionMilliseconds) / 1_000
                guard let duration, duration >= requiredDuration else {
                    throw ToolError.invalid("Clip \(index + 1) is too short for the crossfade, or its duration could not be verified.")
                }
            }
            if let duration { durations.append(duration) }
        }

        let staging = output.deletingLastPathComponent().appending(path: ".audio-merge-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Merged.\(options.format.rawValue)")
        await progress(0.05)
        try await ExternalTool.run(
            executable, name: "FFmpeg", arguments: arguments(inputs, output: candidate, options: options), directory: staging
        )
        let audio = try AVAudioFile(forReading: candidate)
        let duration = Double(audio.length) / audio.fileFormat.sampleRate
        guard duration.isFinite, duration > 0, audio.fileFormat.sampleRate == Double(options.sampleRate),
              audio.fileFormat.channelCount == (options.stereo ? 2 : 1) else {
            throw ToolError.invalid("The merged file did not have the expected audio format.")
        }
        if durations.count == inputs.count {
            let transition = options.transition == .cut ? 0 : Double(options.transitionMilliseconds * (inputs.count - 1)) / 1_000
            let expected = durations.reduce(0, +) + (options.transition == .crossfade ? -transition : transition)
            guard abs(duration - expected) <= max(0.1, Double(inputs.count) * 0.025) else {
                throw ToolError.invalid("The output duration did not match the selected clips and transition.")
            }
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        let seconds = duration.formatted(.number.precision(.fractionLength(0...2)))
        return "\(inputs.count) clips · \(seconds) s · \(options.format.title)"
    }

    private static func arguments(_ inputs: [URL], output: URL, options: AudioMergeOptions) -> [String] {
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-n"]
        for input in inputs {
            args += ["-protocol_whitelist", "file", "-format_whitelist",
                     "aac,aiff,amr,ape,asf,caf,flac,matroska,webm,mov,mp3,ogg,wav,wv", "-i", input.path]
        }
        let rate = options.sampleRate
        let layout = options.stereo ? "stereo" : "mono"
        let samples = options.transition == .cut ? 0 : options.transitionMilliseconds * rate / 1_000
        var filters = inputs.indices.map { index in
            let padding = options.transition == .gap && index < inputs.count - 1 ? ",apad=pad_len=\(samples)" : ""
            return "[\(index):a:0]aresample=\(rate),aformat=sample_fmts=fltp:channel_layouts=\(layout),asetpts=N/SR/TB\(padding)[a\(index)]"
        }
        if options.transition == .crossfade {
            var previous = "a0"
            for index in inputs.indices.dropFirst() {
                let result = index == inputs.count - 1 ? "merged" : "mix\(index)"
                filters.append("[\(previous)][a\(index)]acrossfade=ns=\(samples):c1=tri:c2=tri[\(result)]")
                previous = result
            }
        } else {
            let clips = inputs.indices.map { "[a\($0)]" }.joined()
            filters.append("\(clips)concat=n=\(inputs.count):v=0:a=1[merged]")
        }
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[merged]",
                 "-map_metadata", "-1", "-map_chapters", "-1"]
        let encoding = switch options.format {
        case .m4a: ["-c:a", "aac", "-b:a", "192k", "-f", "ipod"]
        case .mp3: ["-c:a", "libmp3lame", "-b:a", "192k", "-f", "mp3"]
        case .flac: ["-c:a", "flac", "-sample_fmt", "s32", "-f", "flac"]
        case .wav: ["-c:a", "pcm_s24le", "-f", "wav"]
        case .aiff: ["-c:a", "pcm_s24be", "-f", "aiff"]
        }
        return args + encoding + [output.path]
    }
}
