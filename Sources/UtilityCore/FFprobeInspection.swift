import Foundation

enum FFprobeInspection {
    static func inspect(_ input: URL, executable: URL) async throws -> MediaInspectionReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("inspection.json")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try await ExternalTool.run(executable, name: "ffprobe", arguments: [
            "-v", "error", "-protocol_whitelist", "file", "-show_format", "-show_streams",
            "-of", "json", "-i", input.path
        ], directory: directory, standardOutput: handle)
        try Task.checkCancellation()
        let data = try Data(contentsOf: output)
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var format = document["format"] as? [String: Any],
              let streams = document["streams"] as? [[String: Any]],
              streams.contains(where: { $0["codec_type"] as? String == "audio" || $0["codec_type"] as? String == "video" })
        else { throw ToolError.invalid("ffprobe found no video or audio tracks.") }

        format["filename"] = input.lastPathComponent
        document["format"] = format
        var sections = [MediaInspectionReport.Section(title: "File", rows: [
            MediaInspection.row("Filename", input.lastPathComponent),
            MediaInspection.row("Container", string(format["format_long_name"]) ?? string(format["format_name"])),
            MediaInspection.row("Duration", MediaInspection.seconds(number(format["duration"]))),
            MediaInspection.row("File size", string(format["size"]).flatMap(Int64.init).map(MediaInspection.bytes)),
            MediaInspection.row("Overall bitrate (reported)", MediaInspection.bitrate(number(format["bit_rate"])))
        ])]
        for (index, stream) in streams.enumerated() {
            sections.append(streamSection(stream, fallbackIndex: index))
        }
        let tags = tagRows(format["tags"])
        if !tags.isEmpty { sections.append(MediaInspectionReport.Section(title: "Metadata", rows: tags)) }
        let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        return MediaInspectionReport(sections: sections, json: json)
    }

    private static func streamSection(_ stream: [String: Any], fallbackIndex: Int) -> MediaInspectionReport.Section {
        let type = string(stream["codec_type"]) ?? "Other"
        var rows = [
            MediaInspection.row("Codec", string(stream["codec_name"])),
            MediaInspection.row("Profile", string(stream["profile"])),
            MediaInspection.row("Duration", MediaInspection.seconds(number(stream["duration"]))),
            MediaInspection.row("Bitrate (reported)", MediaInspection.bitrate(number(stream["bit_rate"])))
        ]
        if type == "video" {
            let rotation = (stream["side_data_list"] as? [[String: Any]])?
                .compactMap { number($0["rotation"]) }.first
            let width = number(stream["width"])
            let height = number(stream["height"])
            let swapsAxes = rotation.map { abs(abs($0.truncatingRemainder(dividingBy: 180)) - 90) < 0.01 } ?? false
            rows += [
                MediaInspection.row("Dimensions", MediaInspection.dimensions(swapsAxes ? height : width, swapsAxes ? width : height)),
                MediaInspection.row("Frame-rate timing base", MediaInspection.frameRate(rate(stream["r_frame_rate"]))),
                MediaInspection.row("Frame rate (average)", MediaInspection.frameRate(rate(stream["avg_frame_rate"]))),
                MediaInspection.row("Frame timing", "Unavailable from stream summary")
            ]
        } else if type == "audio" {
            rows += [
                MediaInspection.row("Sample rate", string(stream["sample_rate"]).map { $0 + " Hz" }),
                MediaInspection.row("Channels", string(stream["channels"]))
            ]
        }
        rows += tagRows(stream["tags"])
        return MediaInspectionReport.Section(
            title: "\(type.capitalized) stream \(string(stream["index"]) ?? String(fallbackIndex))", rows: rows
        )
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String, value != "N/A" { return value }
        return (value as? NSNumber)?.stringValue
    }

    private static func number(_ value: Any?) -> Double? {
        string(value).flatMap(Double.init)
    }

    private static func rate(_ value: Any?) -> Double? {
        guard let parts = string(value)?.split(separator: "/"), parts.count == 2,
              let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0
        else { return nil }
        return numerator / denominator
    }

    private static func tagRows(_ value: Any?) -> [MediaInspectionReport.Row] {
        guard let tags = value as? [String: Any] else { return [] }
        return tags.keys.sorted().compactMap { key in
            string(tags[key]).map { MediaInspection.row(key, $0) }
        }
    }
}
