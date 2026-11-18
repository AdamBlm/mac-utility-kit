import Foundation

enum FFmpegEncoding {
    static func export(
        _ input: URL, to output: URL, using executable: URL, options: ToolOptions, sample: Bool
    ) async throws {
        let hevc = options.videoCodec == .hevc
        let quality: String
        switch options.videoQuality {
        case .smaller: quality = hevc ? "28" : "26"
        case .balanced: quality = hevc ? "23" : "21"
        case .higher: quality = hevc ? "20" : "18"
        }

        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-protocol_whitelist", "file",
            "-noautorotate", "-i", input.path,
            "-map", "0:v:0", "-map", "0:a?",
            "-c:v", hevc ? "libx265" : "libx264", "-preset", "medium", "-crf", quality,
            "-c:a", "aac"
        ]
        if hevc { arguments += ["-tag:v", "hvc1"] }
        if sample { arguments += ["-t", "5"] }
        arguments += ["-f", options.videoFormat == .mov ? "mov" : "mp4", output.path]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments,
                                   directory: output.deletingLastPathComponent())

    }
}
