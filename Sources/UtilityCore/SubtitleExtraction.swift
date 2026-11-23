import Foundation

package enum ExtractedSubtitleFormat: String, CaseIterable, Identifiable, Sendable {
    case srt = "SRT"
    case vtt = "WebVTT"

    package var id: Self { self }
    package var fileExtension: String { self == .srt ? "srt" : "vtt" }

    var encoder: String { self == .srt ? "srt" : "webvtt" }
}

package struct EmbeddedSubtitleTrack: Decodable, Identifiable, Equatable, Sendable {
    struct Disposition: Decodable, Equatable, Sendable {
        let forced: Int?
        let hearingImpaired: Int?

        enum CodingKeys: String, CodingKey {
            case forced
            case hearingImpaired = "hearing_impaired"
        }
    }

    let index: Int
    let codec: String?
    let tags: [String: String]?
    let disposition: Disposition?

    enum CodingKeys: String, CodingKey {
        case index, tags, disposition
        case codec = "codec_name"
    }

    private static let textCodecs: Set<String> = [
        "ass", "ssa", "subrip", "text", "mov_text", "webvtt", "microdvd", "mpl2", "pjs",
        "realtext", "sami", "stl", "subviewer", "subviewer1", "vplayer", "jacosub", "ttml"
    ]

    package var id: Int { index }
    package var supportsTextExport: Bool { codec.map { Self.textCodecs.contains($0) } ?? false }

    package var label: String {
        let tags = tags ?? [:]
        let language = tags.first { $0.key.caseInsensitiveCompare("language") == .orderedSame }?.value
        let title = tags.first { $0.key.caseInsensitiveCompare("title") == .orderedSame }?.value
        var components = ["Track \(index)"]
        if let language, !language.isEmpty, language != "und" { components.append(language) }
        if let title, !title.isEmpty { components.append(title) }
        if let codec { components.append(codec) }
        if disposition?.forced == 1 { components.append("Forced") }
        if disposition?.hearingImpaired == 1 { components.append("SDH") }
        if !supportsTextExport { components.append("Text export unavailable") }
        return components.joined(separator: " · ")
    }
}

package struct SubtitleInventory: Sendable {
    package let tracks: [EmbeddedSubtitleTrack]

    package let selection: URL
    let version: LocalInputFile.Version
}

package enum SubtitleExtraction {
    private static let inputFormats = "mov,matroska,webm,avi,mpegts,mpeg,asf,flv,mxf,ogg"
    private static let maximumSubtitleBytes = 32 * 1024 * 1024

    private struct ProbeReport: Decodable {
        let streams: [EmbeddedSubtitleTrack]
    }

    package static func inspect(_ source: URL, executable: URL) async throws -> SubtitleInventory {
        let version = try LocalInputFile.Version.read(source)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("streams.json")
        try Data().write(to: report)
        let output = try FileHandle(forWritingTo: report)
        defer { try? output.close() }
        try await ExternalTool.run(executable, name: "ffprobe", arguments: [
            "-v", "error", "-protocol_whitelist", "file", "-format_whitelist", inputFormats,
            "-select_streams", "s",
            "-show_entries", "stream=index,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired",
            "-of", "json", "-i", version.resolved.path
        ], directory: directory, standardOutput: output)
        try Task.checkCancellation()
        guard (try? LocalInputFile.Version.read(source)) == version else {
            throw ToolError.invalid("The video changed while its subtitle tracks were being inspected.")
        }
        let data = try read(report, maximumBytes: 2 * 1024 * 1024)
        let tracks = try JSONDecoder().decode(ProbeReport.self, from: data).streams
        guard tracks.allSatisfy({ $0.id >= 0 }), Set(tracks.map(\.id)).count == tracks.count else {
            throw ToolError.invalid("ffprobe reported invalid subtitle track numbers.")
        }
        return SubtitleInventory(tracks: tracks, selection: source, version: version)
    }

    package static func extract(
        _ track: EmbeddedSubtitleTrack, from inventory: SubtitleInventory, as format: ExtractedSubtitleFormat,
        executable: URL
    ) async throws -> Data {
        guard inventory.tracks.contains(track), track.supportsTextExport else {
            throw ToolError.invalid("Choose a text subtitle track to export as SRT or WebVTT.")
        }
        guard (try? LocalInputFile.Version.read(inventory.selection)) == inventory.version else {
            throw ToolError.invalid("The video changed. Inspect its subtitle tracks again.")
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("captions").appendingPathExtension(format.fileExtension)
        // FFmpeg can exit successfully at its size cutoff. Place it above the
        // accepted size so the read rejects a cutoff instead of saving it.
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-n", "-protocol_whitelist", "file",
            "-format_whitelist", inputFormats, "-i", inventory.version.resolved.path,
            "-map", "0:\(track.id)", "-map_metadata", "-1", "-map_chapters", "-1",
            "-c:s", format.encoder, "-f", format.encoder, "-fs", String(maximumSubtitleBytes + 1), output.path
        ], directory: directory)
        try Task.checkCancellation()
        guard (try? LocalInputFile.Version.read(inventory.selection)) == inventory.version else {
            throw ToolError.invalid("The video changed during extraction. Inspect it again.")
        }
        let data = try read(output, maximumBytes: maximumSubtitleBytes)
        guard let text = String(data: data, encoding: .utf8),
              (format != .vtt || text.hasPrefix("WEBVTT")), text.contains(" --> ") else {
            throw ToolError.invalid("The selected subtitle track did not produce any readable cues.")
        }
        return data
    }

    private static func read(_ file: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ToolError.invalid("The subtitle data exceeds the size limit.") }
        return data
    }

    private static func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }
}
