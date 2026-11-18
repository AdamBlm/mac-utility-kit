import Foundation

enum FFmpegVideoConversion {
    static func export(
        _ input: URL, to output: URL, options: VideoConversionOptions, executable: URL
    ) async throws {
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n",
            "-protocol_whitelist", "file", "-i", input.path
        ]

        switch options.mode {
        case .passthrough:
            // Keep all container-compatible streams and fail if the muxer cannot write them.
            arguments += ["-map", "0"]
            if options.audio == .remove { arguments += ["-map", "-0:a?"] }
            arguments += ["-c", "copy"]
        case .transcode:
            arguments += ["-map", "0:V:0"]
            if options.audio == .keep { arguments += ["-map", "0:a?"] }
            switch options.codec {
            case .h264: arguments += ["-c:v", "libx264", "-preset", "medium", "-crf", "18"]
            case .hevc: arguments += ["-c:v", "libx265", "-preset", "medium", "-crf", "20", "-tag:v", "hvc1"]
            case .vp9: arguments += ["-c:v", "libvpx-vp9", "-crf", "24", "-b:v", "0"]
            }
            if options.audio == .keep {
                arguments += ["-c:a", options.format == .webm ? "libopus" : "aac"]
            }
            var filters: [String] = []
            if let height = options.maximumHeight {
                filters.append("scale=-2:trunc(min(ih\\,\(height))/2)*2")
            }
            if let rate = options.frameRate { filters.append("fps=\(rate)") }
            if !filters.isEmpty { arguments += ["-vf", filters.joined(separator: ",")] }
        }

        arguments += ["-f", options.format.ffmpegMuxer, output.path]
        let directory = output.deletingLastPathComponent()
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments, directory: directory)
        if options.format == .webm {
            var validation = ["-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "file"]
            if options.mode == .transcode { validation += ["-c:v", "vp9"] }
            validation += ["-i", output.path, "-map", "0:V:0", "-frames:v", "1", "-f", "null", "-"]
            try await ExternalTool.run(executable, name: "FFmpeg", arguments: validation, directory: directory)
        }
    }
}
