import Foundation

enum FFmpegEncoding {
    static func export(
        _ input: URL, to output: URL, using executable: URL, options: ToolOptions, sample: Bool
    ) async throws {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolError.invalid("Choose an executable FFmpeg binary.")
        }
        let hevc = options.videoCodec == .hevc
        let quality: String
        switch options.videoQuality {
        case .smaller: quality = hevc ? "28" : "26"
        case .balanced: quality = hevc ? "23" : "21"
        case .higher: quality = hevc ? "20" : "18"
        }

        let log = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".log")
        try Data().write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = executable
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
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        try process.run()
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(80))
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else {
            let tail = try FileHandle(forReadingFrom: log)
            defer { try? tail.close() }
            let length = try tail.seekToEnd()
            try tail.seek(toOffset: length > 2048 ? length - 2048 : 0)
            let message = String(decoding: try tail.readToEnd() ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError.invalid(message.isEmpty ? "FFmpeg could not encode this video." : message)
        }
    }
}
