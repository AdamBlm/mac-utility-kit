import Foundation

enum FFmpegVideoConversion {
    static func checkWebMPassthrough(_ input: URL, audio: VideoConversionAudio, executable: URL) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: ".webm-check-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n",
                         "-protocol_whitelist", "file", "-i", input.path]
            // Require normal video, then check the exact set of streams used by export.
            + ["-map", "0:V:0", "-map", "-0:V:0"]
            + passthroughArguments(audio: audio)
            + ["-t", "0", "-f", "webm", folder.appending(path: "Check.webm").path]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments, directory: folder)
    }

    private static func passthroughArguments(audio: VideoConversionAudio) -> [String] {
        var arguments = ["-map", "0"]
        if audio == .remove { arguments += ["-map", "-0:a?"] }
        return arguments + ["-c", "copy"]
    }

    static func export(
        _ input: URL, to output: URL, options: VideoConversionOptions, executable: URL
    ) async throws -> String? {
        let webm = options.format == .webm
        let logLevel = webm ? "repeat+level+info" : "error"
        var arguments = [
            "-nostdin", "-hide_banner", "-nostats", "-loglevel", logLevel, "-n",
            "-protocol_whitelist", "file", "-i", input.path
        ]

        switch options.mode {
        case .passthrough:
            // Keep all container-compatible streams and fail if the muxer cannot write them.
            arguments += passthroughArguments(audio: options.audio)
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
        guard webm else {
            try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments, directory: directory)
            return nil
        }

        let scratch = directory.appending(path: ".video-streams-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputLog = scratch.appending(path: "Input.log")
        let outputLog = scratch.appending(path: "Output.log")
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments, directory: directory,
                                   diagnostics: inputLog)
        var validation = ["-nostdin", "-hide_banner", "-nostats", "-loglevel", logLevel, "-xerror",
                          "-protocol_whitelist", "file"]
        if options.mode == .transcode { validation += ["-c:v", "vp9"] }
        validation += ["-i", output.path, "-map", "0:V:0", "-frames:v", "1", "-f", "null", "-"]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: validation, directory: directory,
                                   diagnostics: outputLog)
        return try FFmpegStreamInventory.webMSummary(input: inputLog, output: outputLog)
    }
}
