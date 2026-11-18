import Foundation

public struct TranscriptionOptions: Equatable, Sendable {
    public var executable: URL?
    public var model: URL?
    public var language = "auto"
    public var start = 0.0
    public var end: Double?

    public init() {}
}

public enum TranscriptFormat: String, CaseIterable, Identifiable, Sendable {
    case txt = "TXT"
    case srt = "SRT"
    case vtt = "VTT"

    public var id: Self { self }
    public var fileExtension: String { rawValue.lowercased() }
}

public enum Transcription {
    public static func run(
        _ input: URL, options: TranscriptionOptions, progress: @Sendable (Double) async -> Void
    ) async throws -> [SubtitleCue] {
        guard let executable = options.executable, executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolError.invalid("Choose a local whisper-cli executable.")
        }
        guard let model = options.model, model.isFileURL,
              try model.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("Choose a local Whisper model file.")
        }
        let language = options.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard language == "auto" || ((2...3).contains(language.utf8.count) && language.utf8.allSatisfy({ (97...122).contains($0) })) else {
            throw ToolError.invalid("Enter a Whisper language code or choose auto-detect.")
        }
        let selection = try await TranscriptionAudio.selection(input, options: options)
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("source.wav")
        let output = directory.appendingPathComponent("transcript")
        try await TranscriptionAudio.normalize(selection, to: wav)
        await progress(0.25)
        try await ExternalTool.run(executable, name: "whisper-cli", arguments: [
            "-m", model.path, "-f", wav.path, "-l", language, "-oj", "-of", output.path, "-np"
        ], directory: directory)
        try Task.checkCancellation()
        let data = try Data(contentsOf: output.appendingPathExtension("json"))
        let cues = try parseWhisperJSON(data, sourceOffset: selection.range.start.seconds,
                                       duration: selection.range.duration.seconds, language: language)
        await progress(1)
        return cues
    }

    public static func render(_ cues: [SubtitleCue], format: TranscriptFormat) -> String {
        let cleaned = cues.compactMap { cue -> SubtitleCue? in
            let text = cue.text.split(whereSeparator: \.isNewline).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SubtitleCue(startMilliseconds: cue.startMilliseconds, endMilliseconds: cue.endMilliseconds, text: text)
        }
        switch format {
        case .txt: return cleaned.map(\.text).joined(separator: "\n") + "\n"
        case .srt: return SubRip.render(cleaned)
        case .vtt:
            let lines = cleaned.map { cue in
                let start = SubRip.timestamp(cue.startMilliseconds).replacingOccurrences(of: ",", with: ".")
                let end = SubRip.timestamp(cue.endMilliseconds).replacingOccurrences(of: ",", with: ".")
                let text = cue.text.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                return "\(start) --> \(end)\n\(text)\n"
            }
            return "WEBVTT\n\n" + lines.joined(separator: "\n")
        }
    }

    static func parseWhisperJSON(_ data: Data, sourceOffset: Double, duration: Double, language: String) throws -> [SubtitleCue] {
        let document: WhisperOutput
        do { document = try JSONDecoder().decode(WhisperOutput.self, from: data) }
        catch { throw ToolError.invalid("The selected whisper-cli did not produce valid timestamped JSON.") }
        if language != "auto", let detected = document.result?.language, detected != language {
            throw ToolError.invalid("Whisper returned language \(detected). Choose a compatible model or auto-detect.")
        }
        guard sourceOffset.isFinite, duration.isFinite, sourceOffset >= 0, duration > 0,
              sourceOffset + duration < 4_000_000_000 else {
            throw ToolError.invalid("The audio timeline is outside the supported range.")
        }
        let origin = Int((sourceOffset * 1000).rounded())
        let limit = Int((duration * 1000).rounded())
        var previousEnd = 0
        var cues: [SubtitleCue] = []
        for segment in document.transcription {
            let from = segment.offsets.from
            let to = segment.offsets.to
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper timestamps are quantized and may overshoot the final frame.
            guard from >= previousEnd, from < to, to <= limit + 500 else {
                throw ToolError.invalid("Whisper returned an invalid or overlapping timestamp.")
            }
            previousEnd = to
            let end = min(to, limit)
            if from < end, !text.isEmpty {
                cues.append(SubtitleCue(startMilliseconds: origin + from, endMilliseconds: origin + end, text: text))
            }
        }
        return cues
    }
}

private struct WhisperOutput: Decodable {
    struct Result: Decodable {
        let language: String?
    }

    struct Segment: Decodable {
        struct Offsets: Decodable {
            let from: Int
            let to: Int
        }

        let offsets: Offsets
        let text: String
    }

    let result: Result?
    let transcription: [Segment]
}
