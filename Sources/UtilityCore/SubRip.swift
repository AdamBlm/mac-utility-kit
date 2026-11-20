import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public let startMilliseconds: Int
    public let endMilliseconds: Int
    public let text: String

    public init(startMilliseconds: Int, endMilliseconds: Int, text: String) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
    }
}

public enum SubRip {
    private static let maximumImportBytes = 8 * 1024 * 1024

    package static func load(_ url: URL) async throws -> String {
        let data = try await PlainTextDecoding.loadVerifiedBytes(url, maximumBytes: maximumImportBytes)
        try Task.checkCancellation()
        return try decode(data)
    }

    package static func decode(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw ToolError.invalid("Could not read this SRT file as UTF-8, UTF-16, or Windows-1252.")
    }

    public static func parse(_ source: String) throws -> [SubtitleCue] {
        let source = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var groups: [(line: Int, content: [String])] = []
        var current: [String] = []
        var firstLine = 1
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { groups.append((firstLine, current)) }
                current.removeAll(keepingCapacity: true)
            } else {
                if current.isEmpty { firstLine = index + 1 }
                current.append(line)
            }
        }
        if !current.isEmpty { groups.append((firstLine, current)) }
        guard !groups.isEmpty else { throw ToolError.invalid("Import or enter at least one SRT cue.") }

        let cues = try groups.map { group -> SubtitleCue in
            let lines = group.content
            let index = lines[0].trimmingCharacters(in: .whitespaces)
            guard !index.isEmpty, index.utf8.allSatisfy({ (48...57).contains($0) }), lines.count >= 3 else {
                throw ToolError.invalid("Expected a cue number, timing, and text at line \(group.line).")
            }
            let times = lines[1].components(separatedBy: "-->")
            guard times.count == 2, let start = milliseconds(times[0]), let end = milliseconds(times[1]), end > start else {
                throw ToolError.invalid("Invalid subtitle timing at line \(group.line + 1). Use hours:minutes:seconds,milliseconds.")
            }
            let text = lines.dropFirst(2).joined(separator: "\n")
            guard !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else {
                throw ToolError.invalid("Invalid control character at line \(group.line + 2).")
            }
            return SubtitleCue(startMilliseconds: start, endMilliseconds: end, text: text)
        }.sorted { $0.startMilliseconds < $1.startMilliseconds }

        for (left, right) in zip(cues, cues.dropFirst()) where left.endMilliseconds > right.startMilliseconds {
            throw ToolError.invalid("Subtitle cues at \(timestamp(left.startMilliseconds)) and \(timestamp(right.startMilliseconds)) overlap.")
        }
        return cues
    }

    public static func render(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.startMilliseconds)) --> \(timestamp(cue.endMilliseconds))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func timestamp(_ milliseconds: Int) -> String {
        let value = max(0, milliseconds)
        return String(format: "%02d:%02d:%02d,%03d", value / 3_600_000, (value / 60_000) % 60,
                      (value / 1000) % 60, value % 1000)
    }

    private static func milliseconds(_ timestamp: String) -> Int? {
        let text = timestamp.trimmingCharacters(in: .whitespaces)
        let match = text.wholeMatch(of: /([0-9]{2,6}):([0-5][0-9]):([0-5][0-9])[,.]([0-9]{3})/)
        guard let match, let hours = Int(match.1), let minutes = Int(match.2),
              let seconds = Int(match.3), let millis = Int(match.4) else { return nil }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }
}
