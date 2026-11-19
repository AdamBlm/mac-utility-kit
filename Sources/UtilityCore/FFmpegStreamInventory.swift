import Foundation

/// Reads the demuxer's stream inventory from the beginning of FFmpeg's info log.
enum FFmpegStreamInventory {
    private struct Stream {
        let kind: String
        let codec: String
    }

    static func webMSummary(input: URL, output: URL, audioKbps: Int? = nil) throws -> String {
        let original = try streams(input)
        let converted = try streams(output)
        guard converted.contains(where: { $0.kind == "video" }) else {
            return "WebM · First video frame decoded · Stream details unavailable"
        }

        let video = converted.filter { $0.kind == "video" }.map(\.codec).joined(separator: ", ")
        let audioStreams = converted.filter { $0.kind == "audio" }
        let audio = audioStreams.map(\.codec).joined(separator: ", ")
        var details = ["WebM", "Video: " + video, audio.isEmpty ? "No audio" : "Audio: " + audio]
        if let audioKbps, !audioStreams.isEmpty {
            details.append("Audio target: \(audioKbps) kb/s per track")
        }
        let additional = Dictionary(grouping: converted.filter { $0.kind != "video" && $0.kind != "audio" }, by: \.kind)
        for kind in additional.keys.sorted() {
            let codecs = additional[kind]?.map(\.codec).joined(separator: ", ") ?? ""
            details.append(kind.capitalized + ": " + codecs)
        }
        if original.contains(where: { $0.kind == "video" }) {
            let byKind = Dictionary(grouping: original, by: \.kind)
            let retained = Dictionary(grouping: converted, by: \.kind)
            for kind in byKind.keys.sorted() {
                let dropped = (byKind[kind]?.count ?? 0) - (retained[kind]?.count ?? 0)
                if dropped > 0 {
                    details.append("\(dropped) \(kind) track\(dropped == 1 ? "" : "s") dropped")
                }
            }
        } else {
            details.append("Source stream details unavailable")
        }
        return details.joined(separator: " · ")
    }

    private static func streams(_ log: URL) throws -> [Stream] {
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        let header = /^\[info\]   Stream #0:(\d+)(?:\[[^\]]+\])?(?:\([^)]*\))?: (Video|Audio|Subtitle|Data|Attachment|Unknown): ([A-Za-z0-9_]+)/
        var foundInput = false
        var complete = false
        var streams: [Stream] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[info] Input #0,") { foundInput = true }
            guard foundInput else { continue }
            if line.hasPrefix("[info] Stream mapping:") || line.hasPrefix("[info] Output #") {
                complete = true
                break
            }
            guard line.hasPrefix("[info]   Stream #0:") else { continue }
            guard let match = line.prefixMatch(of: header), Int(match.1) == streams.count else { return [] }
            let name = String(match.3)
            let codec = switch name {
            case "vp8", "vp9", "av1": name.uppercased()
            case "opus", "vorbis": name.capitalized
            default: name
            }
            streams.append(Stream(kind: match.2.lowercased(), codec: codec))
        }
        return complete ? streams : []
    }
}
