import Foundation

enum FFmpegAudioConvert {
    static func export(_ input: URL, to output: URL, options: AudioConvertOptions) async throws {
        guard let executable = options.ffmpegExecutable else {
            throw ToolError.invalid("Choose an FFmpeg executable for this format.")
        }
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-protocol_whitelist", "file",
            "-i", input.path, "-map", "0:a:0", "-vn",
            "-map_metadata", options.preservesMetadata ? "0" : "-1"
        ]
        if !options.preservesMetadata {
            arguments += ["-map_chapters", "-1", "-map_metadata:s:a", "-1"]
        }
        if let channels = options.channels.count { arguments += ["-ac", String(channels)] }
        if let rate = options.sampleRate { arguments += ["-ar", String(rate)] }
        if options.format == .mp3 {
            arguments += ["-c:a", "libmp3lame", "-b:a", "\(options.bitrate)k"]
        } else {
            arguments += ["-c:a", "flac", "-compression_level", String(options.losslessCompression)]
        }
        arguments += ["-f", options.format.rawValue, output.path]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments,
                                   directory: output.deletingLastPathComponent())
    }
}
