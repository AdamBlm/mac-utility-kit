import Foundation

enum FFmpegAudioExtraction {
    static func export(
        _ input: URL, to output: URL, options: AudioExtractionOptions, executable: URL, language: String?
    ) async throws {
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-protocol_whitelist", "file",
            "-i", input.path, "-map", "0:a:0", "-vn",
            "-c:a", options.format == .mp3 ? "libmp3lame" : "flac"
        ]
        if options.format == .mp3 {
            arguments += ["-b:a", String(options.quality.bitrate)]
        }
        if let language { arguments += ["-metadata", "language=\(language)"] }
        arguments += ["-f", options.format.rawValue, output.path]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments,
                                   directory: output.deletingLastPathComponent())
    }
}
