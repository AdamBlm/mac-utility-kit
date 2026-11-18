import Foundation

enum FFmpegVideoTrim {
    private struct Metadata: Decodable {
        struct Format: Decodable {
            let start_time: String?
            let duration: String?
        }
        struct Stream: Decodable {
            struct Disposition: Decodable {
                let attached_pic: Int?
            }

            let codec_name: String?
            let codec_type: String?
            let disposition: Disposition?
            var isVideo: Bool { codec_type == "video" && disposition?.attached_pic != 1 }
        }
        let format: Format
        let streams: [Stream]
    }

    private struct ProbeFrames: Decodable {
        struct Frame: Decodable {
            let best_effort_timestamp_time: String?
        }
        let frames: [Frame]
    }

    static func plan(_ input: URL, options: TrimVideoOptions) async throws -> VideoTrimRange {
        try await withProbeFiles { directory in
            try await analyze(input, options: options, directory: directory).range
        }
    }

    static func export(_ input: URL, to output: URL, options: TrimVideoOptions) async throws -> VideoTrimRange {
        guard let executable = options.ffmpegExecutable else {
            throw ToolError.invalid("Choose an FFmpeg executable for keyframe-aligned copy.")
        }
        let directory = output.deletingLastPathComponent()
        let analysis = try await analyze(input, options: options, directory: directory)
        let range = analysis.range
        let rangeStart = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), range.start)
        let rangeDuration = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), range.duration)
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file",
            "-ss", rangeStart, "-noaccurate_seek", "-i", input.path,
            "-map", "0:V:0", "-map", "0:a?", "-c", "copy", "-t", rangeDuration,
            "-avoid_negative_ts", "make_zero", "-f", "matroska", output.path
        ], directory: directory)
        let result = try await metadata(output, executable: analysis.ffprobe, directory: directory)
        guard result.streams.filter(\.isVideo).map(\.codec_name) == [analysis.videoCodec],
              result.streams.filter({ $0.codec_type == "audio" }).map(\.codec_name) == analysis.audioCodecs,
              let duration = result.format.duration.flatMap(Double.init), duration.isFinite,
              abs(duration - range.duration) <= 0.35 else {
            throw ToolError.invalid("The copied video could not be verified at the planned duration with its original codecs.")
        }
        let expectedFrame = try await firstFrameHash(input, seek: rangeStart, executable: executable, directory: directory)
        let outputFrame = try await firstFrameHash(output, seek: nil, executable: executable, directory: directory)
        guard expectedFrame == outputFrame else {
            throw ToolError.invalid("The copied video did not start on the planned keyframe.")
        }
        return range
    }

    private static func analyze(
        _ input: URL, options: TrimVideoOptions, directory: URL
    ) async throws -> (range: VideoTrimRange, ffprobe: URL, videoCodec: String?, audioCodecs: [String?]) {
        guard input.isFileURL else { throw ToolError.invalid("Choose a local video file.") }
        guard let probe = options.ffprobeExecutable else {
            throw ToolError.invalid("Choose an ffprobe executable to find keyframes.")
        }
        let metadata = try await metadata(input, executable: probe, directory: directory)
        guard let duration = metadata.format.duration.flatMap(Double.init),
              let video = metadata.streams.first(where: \.isVideo) else {
            throw ToolError.invalid("ffprobe could not determine the video duration and codec.")
        }
        let origin = metadata.format.start_time.flatMap(Double.init) ?? 0
        let selected = try VideoTrimRange.validate(start: options.start, end: options.end, duration: duration)
        let frames = try await readProbe(ProbeFrames.self, input: input, executable: probe, directory: directory, arguments: [
            "-select_streams", "V:0", "-skip_frame", "nokey", "-show_frames", "-show_entries", "frame=best_effort_timestamp_time"
        ])
        let keys = frames.frames.compactMap { $0.best_effort_timestamp_time.flatMap(Double.init).map { $0 - origin } }
        let range = try VideoTrimRange.align(selected, to: keys, duration: duration)
        return (range, probe, video.codec_name, metadata.streams.filter { $0.codec_type == "audio" }.map(\.codec_name))
    }

    private static func metadata(_ input: URL, executable: URL, directory: URL) async throws -> Metadata {
        try await readProbe(Metadata.self, input: input, executable: executable, directory: directory, arguments: [
            "-show_format", "-show_streams", "-show_entries", "format=start_time,duration:stream=codec_name,codec_type:stream_disposition=attached_pic"
        ])
    }

    private static func firstFrameHash(
        _ input: URL, seek: String?, executable: URL, directory: URL
    ) async throws -> String {
        let report = directory.appendingPathComponent(UUID().uuidString + ".sha256")
        defer { try? FileManager.default.removeItem(at: report) }
        let seekOptions = seek.map { ["-ss", $0] } ?? []
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: [
            "-hide_banner", "-loglevel", "error", "-xerror", "-nostdin", "-n", "-protocol_whitelist", "file"
        ] + seekOptions + [
            "-i", input.path, "-map", "0:V:0", "-frames:v", "1", "-f", "hash", "-hash", "sha256", report.path
        ], directory: directory)
        let hash = try String(contentsOf: report, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard hash.hasPrefix("SHA256="), hash.count == 71,
              hash != "SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" else {
            throw ToolError.invalid("The copied video did not contain a decodable first frame.")
        }
        return hash
    }

    private static func readProbe<T: Decodable>(
        _ type: T.Type, input: URL, executable: URL, directory: URL, arguments: [String]
    ) async throws -> T {
        let report = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data().write(to: report)
        defer { try? FileManager.default.removeItem(at: report) }
        let handle = try FileHandle(forWritingTo: report)
        defer { try? handle.close() }
        try await ExternalTool.run(executable, name: "ffprobe", arguments: [
            "-v", "error", "-protocol_whitelist", "file"
        ] + arguments + ["-of", "json", "-i", input.path], directory: directory, standardOutput: handle)
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: report))
    }

    private static func withProbeFiles<T>(_ body: (URL) async throws -> T) async throws -> T {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        return try await body(directory)
    }
}
