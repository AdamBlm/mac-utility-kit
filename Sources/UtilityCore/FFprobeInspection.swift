import Foundation

enum FFprobeInspection {
    static func inspect(
        _ input: URL, filename: String, executable: URL, automatic: Bool = false
    ) async throws -> MediaInspectionReport {
        var inputOptions = ["-v", "error", "-protocol_whitelist", "file"]
        if automatic {
            // Skip playlist and other reference-based formats when probing automatically.
            inputOptions += ["-format_whitelist", "mov,matroska,webm,avi,mpegts,mpeg,asf,flv,mxf,ogg,wav,mp3,flac,aiff,aac,ac3,amr,caf"]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("inspection.json")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try await ExternalTool.run(executable, name: "ffprobe", arguments: inputOptions + [
            "-show_format", "-show_streams",
            "-of", "json", "-i", input.path
        ], directory: directory, standardOutput: handle)
        try Task.checkCancellation()
        let data = try Data(contentsOf: output)
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var format = document["format"] as? [String: Any],
              let streams = document["streams"] as? [[String: Any]],
              streams.contains(where: { $0["codec_type"] as? String == "audio" || $0["codec_type"] as? String == "video" })
        else { throw ToolError.invalid("ffprobe found no video or audio tracks.") }

        let timing = try await inspectFrameTiming(input, executable: executable, directory: directory,
                                                  streams: streams, format: format, inputOptions: inputOptions)
        try Task.checkCancellation()
        format["filename"] = filename
        document["format"] = format
        var sections = [MediaInspectionReport.Section(title: "File", rows: [
            MediaInspection.row("Filename", filename),
            MediaInspection.row("Inspection engine", "ffprobe"),
            MediaInspection.row("Container", string(format["format_long_name"]) ?? string(format["format_name"])),
            MediaInspection.row("Duration", MediaInspection.seconds(number(format["duration"]))),
            MediaInspection.row("File size", string(format["size"]).flatMap(Int64.init).map(MediaInspection.bytes)),
            MediaInspection.row("Overall bitrate (reported)", MediaInspection.bitrate(number(format["bit_rate"])))
        ])]
        for (index, stream) in streams.enumerated() {
            sections.append(streamSection(stream, fallbackIndex: index,
                                          frameTiming: string(stream["index"]).flatMap { timing[$0] }))
        }
        let tags = tagRows(format["tags"])
        if !tags.isEmpty { sections.append(MediaInspectionReport.Section(title: "Metadata", rows: tags)) }
        let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        return MediaInspectionReport(sections: sections, json: json)
    }

    private static func inspectFrameTiming(
        _ input: URL, executable: URL, directory: URL, streams: [[String: Any]], format: [String: Any], inputOptions: [String]
    ) async throws -> [String: String] {
        let videos = streams.filter {
            string($0["codec_type"]) == "video" && ($0["disposition"] as? [String: Int])?["attached_pic"] != 1
        }
        guard !videos.isEmpty else { return [:] }
        var windows = ["%+#48"]
        if let duration = number(format["duration"]), duration.isFinite, duration >= 5 {
            let start = number(format["start_time"]) ?? 0
            if start.isFinite {
                for position in [0.5, 0.9] {
                    let time = max(0, start + duration * position)
                    if time.isFinite { windows.append("\(time)%+#48") }
                }
            }
        }

        var intervals: [Int: [Double]] = [:]
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            do {
                let frames = try await frameSample(input, executable: executable, directory: directory,
                                                   filename: "frames-\(index).json", window: window,
                                                   inputOptions: inputOptions)
                // A seek can land at a nearby keyframe. Compare adjacent frames only inside each window.
                let grouped = Dictionary(grouping: frames, by: \.stream)
                for (stream, frames) in grouped {
                    intervals[stream, default: []].append(contentsOf: adjacentIntervals(frames.map(\.timestamp)))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A container or decoder can support metadata inspection without frame sampling.
            }
        }
        return videos.reduce(into: [:]) { findings, stream in
            guard let id = string(stream["index"]), let index = Int(id), let samples = intervals[index],
                  let tick = rate(stream["time_base"]), tick.isFinite, tick > 0 else { return }
            findings[id] = MediaInspection.frameTiming(intervals: samples.map { $0 * tick }, resolution: tick)
        }
    }

    static func adjacentIntervals(_ timestamps: [Int64?]) -> [Double] {
        zip(timestamps, timestamps.dropFirst()).compactMap { previous, next in
            guard let previous, let next else { return nil }
            let (difference, overflow) = next.subtractingReportingOverflow(previous)
            return !overflow && difference > 0 ? Double(difference) : nil
        }
    }

    private struct Frame: Decodable {
        let stream: Int
        let timestamp: Int64?

        enum CodingKeys: String, CodingKey {
            case stream = "stream_index"
            case timestamp = "best_effort_timestamp"
        }
    }

    private struct FrameSample: Decodable {
        let frames: [Frame]
    }

    private static func frameSample(
        _ input: URL, executable: URL, directory: URL, filename: String, window: String, inputOptions: [String]
    ) async throws -> [Frame] {
        let output = directory.appendingPathComponent(filename)
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try await ExternalTool.run(executable, name: "ffprobe", arguments: inputOptions + [
            "-select_streams", "V",
            "-read_intervals", window, "-show_frames",
            "-show_entries", "frame=stream_index,best_effort_timestamp",
            "-of", "json", "-i", input.path
        ], directory: directory, standardOutput: handle)
        try Task.checkCancellation()
        let data = try Data(contentsOf: output)
        return try JSONDecoder().decode(FrameSample.self, from: data).frames
    }

    private static func streamSection(
        _ stream: [String: Any], fallbackIndex: Int, frameTiming: String?
    ) -> MediaInspectionReport.Section {
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
                MediaInspection.row("Frame timing", frameTiming)
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
