import Foundation
import ImageIO

enum FFmpegEncoding {
    static func export(
        _ input: URL, to output: URL, using executable: URL, source: VideoCompression.Source,
        options: ToolOptions, sample: Bool
    ) async throws {
        let advanced = options.videoCompression
        let container = options.videoFormat
        let codec = source.codec
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-protocol_whitelist", "file"
        ]
        if container != .webm { arguments += ["-noautorotate"] }
        arguments += [
            "-i", input.path,
            "-map", "0:V:0", "-map", "0:a?",
            "-c:v", codec.ffmpegEncoder,
            "-c:a", container == .webm ? "libopus" : "aac"
        ]
        if codec != .vp9 { arguments += ["-preset", "medium"] }
        if container == .webm {
            // Opus mapping family 1 uses Vorbis speaker positions. Normalize
            // side-surround aliases to its standard layouts before encoding.
            arguments += ["-mapping_family", "1", "-af",
                          "aformat=channel_layouts=mono|stereo|3.0|quad|5.0|5.1|6.1|7.1"]
        }
        switch advanced.rateControl {
        case .preset:
            let quality = presetQuality(options.videoQuality, codec: codec)
            arguments += ["-crf", String(quality)]
            if codec == .vp9 { arguments += ["-b:v", "0"] }
        case .constantQuality:
            arguments += ["-crf", String(advanced.quality)]
            if codec == .vp9 { arguments += ["-b:v", "0"] }
        case .averageBitrate:
            arguments += ["-b:v", "\(advanced.videoKbps)k"]
        }
        if let rate = advanced.audioKbps { arguments += ["-b:a", "\(rate)k"] }
        if source.hdr { arguments += ["-pix_fmt", "yuv420p10le"] }
        if container == .webm {
            let size = CGRect(origin: .zero, size: source.size).applying(source.transform).standardized.size
            // Autorotation happens before the filters, and the WebM output
            // uses square pixels at the planned display-oriented dimensions.
            arguments += ["-vf", "scale=\(Int(size.width.rounded())):\(Int(size.height.rounded())),setsar=1"]
        } else if source.size != source.naturalSize {
            arguments += ["-vf", "scale=\(Int(source.size.width)):\(Int(source.size.height))"]
        }
        if codec == .hevc { arguments += ["-tag:v", "hvc1"] }
        if sample { arguments += ["-t", "5"] }
        arguments += ["-f", container.muxer, output.path]
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: arguments,
                                   directory: output.deletingLastPathComponent())
    }

    static func list(_ option: String, using executable: URL) async throws -> Set<String> {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let log = scratch.appendingPathComponent("listing")
        try Data().write(to: log)
        let stdout = try FileHandle(forWritingTo: log)
        defer { try? stdout.close() }
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: ["-nostdin", "-hide_banner", option],
                                   directory: scratch, standardOutput: stdout)
        let text = try String(contentsOf: log, encoding: .utf8)
        return Set(text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let items = line.split(whereSeparator: \.isWhitespace)
            guard items.count >= 2, items[1] != "=", items[0] != "--" else { return [] }
            return items[1].split(separator: ",").map(String.init)
        })
    }

    static func verifyWebM(_ output: URL, source: VideoCompression.Source, using executable: URL) async throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let display = CGRect(origin: .zero, size: source.size).applying(source.transform).standardized
        let width = Int(display.width.rounded())
        let height = Int(display.height.rounded())
        let frame = scratch.appendingPathComponent("frame.png")
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-n",
            "-i", output.path, "-map", "0:V:0", "-frames:v", "1", "-an", "-c:v", "png",
            "-f", "image2", "-update", "1", frame.path
        ], directory: scratch)
        guard let image = CGImageSourceCreateWithURL(frame as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == width,
              props[kCGImagePropertyPixelHeight] as? Int == height else {
            throw ToolError.invalid("FFmpeg could not confirm the WebM frame dimensions and orientation.")
        }
    }

    private static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    private static func presetQuality(_ quality: VideoQuality, codec: VideoCodec) -> Int {
        switch (quality, codec) {
        case (.smaller, .vp9): 36
        case (.balanced, .vp9): 28
        case (.higher, .vp9): 22
        case (.smaller, .hevc): 28
        case (.balanced, .hevc): 23
        case (.higher, .hevc): 20
        case (.smaller, _): 26
        case (.balanced, _): 21
        case (.higher, _): 18
        }
    }
}
