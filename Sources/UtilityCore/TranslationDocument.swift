import Foundation

public struct TranslationDocument: Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case text = "Text"
        case srt = "SRT"
        case vtt = "WebVTT"
        public var id: Self { self }
        public var fileExtension: String {
            switch self {
            case .text: "txt"
            case .srt: "srt"
            case .vtt: "vtt"
            }
        }
    }

    private struct Line: Sendable {
        let text: String
        let ending: String
    }

    private struct Dialogue: Sendable {
        let range: Range<String.Index>
        let line: Int
    }

    private static let webVTTInlineMarkup = try! NSRegularExpression(
        pattern: #"^<(?:/(?:b|i|u|c|v)|(?:b|i|u|c)(?:\.[^\s.<>]+)*|v(?:\.[^\s.<>]+)*[ \t]+[^<>]+)>$"#
    )

    private static let maximumBytes = 512 * 1024
    private static let maximumRequests = 3_000
    private static let maximumLineBytes = 8_000

    public let kind: Kind
    private let lines: [Line]
    private let editableIndices: [Int]
    private let dialogue: [Dialogue]

    public var requests: [String] { dialogue.map { String(lines[$0.line].text[$0.range]) } }

    public init(_ source: String, kind: Kind) throws {
        guard source.utf8.count <= Self.maximumBytes else {
            throw ToolError.invalid("Choose text or subtitles no larger than 512 KiB.")
        }
        let lines = Self.splitLines(source)
        let indices = try Self.editableLines(lines, kind: kind)
        let dialogue = try indices.flatMap { index in
            let line = lines[index].text
            if kind == .vtt {
                let tags = try Self.webVTTMarkup(in: line, number: index + 1)
                return Self.webVTTDialogue(in: line, between: tags)
                    .compactMap { $0.map { Dialogue(range: $0, line: index) } }
            }
            return [Dialogue(range: line.startIndex..<line.endIndex, line: index)]
        }
        guard dialogue.count <= Self.maximumRequests else {
            throw ToolError.invalid("Translate up to 3,000 dialogue segments per operation.")
        }
        guard indices.allSatisfy({ lines[$0].text.utf8.count <= Self.maximumLineBytes }) else {
            throw ToolError.invalid("Break lines over 8,000 UTF-8 bytes into smaller paragraphs before translating.")
        }
        guard !dialogue.isEmpty else { throw ToolError.invalid("The source does not contain text to translate.") }
        self.kind = kind
        self.lines = lines
        self.editableIndices = indices
        self.dialogue = dialogue
    }

    public func rendering(_ translations: [String]) throws -> String {
        guard translations.count == dialogue.count else {
            throw ToolError.invalid("The translation did not return all dialogue segments.")
        }
        var output = ""
        var translationIndex = 0
        for (index, line) in lines.enumerated() {
            var cursor = line.text.startIndex
            while translationIndex < dialogue.count, dialogue[translationIndex].line == index {
                let range = dialogue[translationIndex].range
                let translated = translations[translationIndex].split(whereSeparator: \.isNewline).joined(separator: " ")
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolError.invalid("The translation returned an empty segment at source line \(index + 1).")
                }
                output.append(contentsOf: line.text[cursor..<range.lowerBound])
                output += translated
                cursor = range.upperBound
                translationIndex += 1
            }
            output.append(contentsOf: line.text[cursor...])
            output += line.ending
        }
        try validateEdit(output)
        return output
    }

    public func validateEdit(_ output: String) throws {
        _ = try applyingEdits(output)
    }

    public func applyingEdits(_ output: String) throws -> String {
        guard kind != .text else { return output }
        let proposed = try TranslationDocument(output, kind: kind)
        guard proposed.lines.count == lines.count, proposed.editableIndices == editableIndices else {
            throw ToolError.invalid("Keep subtitle cue and line structure intact. Edit only the dialogue lines.")
        }
        let editable = Set(editableIndices)
        guard lines.indices.allSatisfy({ editable.contains($0) || lines[$0].text.utf8.elementsEqual(proposed.lines[$0].text.utf8) }) else {
            throw ToolError.invalid("Keep subtitle timestamps, identifiers, and metadata intact.")
        }
        if kind == .vtt {
            for index in editableIndices {
                let originalTags = try Self.webVTTMarkup(in: lines[index].text, number: index + 1)
                let proposedTags = try Self.webVTTMarkup(in: proposed.lines[index].text, number: index + 1)
                guard originalTags.map({ Array($0.utf8) }) == proposedTags.map({ Array($0.utf8) }) else {
                    throw ToolError.invalid("Keep WebVTT formatting tags intact at line \(index + 1).")
                }
                let originalSlots = Self.webVTTDialogue(in: lines[index].text, between: originalTags).map { $0 != nil }
                let proposedSlots = Self.webVTTDialogue(in: proposed.lines[index].text, between: proposedTags).map { $0 != nil }
                guard originalSlots == proposedSlots else {
                    throw ToolError.invalid("Keep dialogue within its original WebVTT formatting tags at line \(index + 1).")
                }
            }
        }
        return lines.indices.map { index in proposed.lines[index].text + lines[index].ending }.joined()
    }

    private static func splitLines(_ source: String) -> [Line] {
        var lines: [Line] = []
        var start = source.startIndex
        for index in source.indices where source[index].isNewline {
            let character = source[index]
            guard character == "\n" || character == "\r" || character == "\r\n" else { continue }
            lines.append(Line(text: String(source[start..<index]), ending: String(character)))
            start = source.index(after: index)
        }
        if start < source.endIndex { lines.append(Line(text: String(source[start...]), ending: "")) }
        return lines
    }

    private static func editableLines(_ lines: [Line], kind: Kind) throws -> [Int] {
        if kind == .text { return lines.indices.filter { !blank(lines[$0].text) } }
        var cursor = 0
        if kind == .vtt {
            guard let firstLine = lines.first?.text else { throw ToolError.invalid("WebVTT requires a WEBVTT header.") }
            let header = firstLine.hasPrefix("\u{FEFF}") ? firstLine.dropFirst() : firstLine[...]
            guard header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t") else {
                throw ToolError.invalid("WebVTT requires a WEBVTT header.")
            }
            cursor = 1
            while cursor < lines.count, !blank(lines[cursor].text) {
                guard !lines[cursor].text.contains("-->") else {
                    throw ToolError.invalid("Separate the WebVTT header from cues with a blank line.")
                }
                cursor += 1
            }
        }

        let timestamp = kind == .srt ? #"[0-9]{2,}:[0-5][0-9]:[0-5][0-9],[0-9]{3}"#
            : #"(?:[0-9]{2,}:)?[0-5][0-9]:[0-5][0-9]\.[0-9]{3}"#
        let timing = try NSRegularExpression(pattern: "^(\(timestamp))[ \t]+-->[ \t]+(\(timestamp))([ \t].*)?$")
        let otherMarkup = #"\\[Nn]|\{\\[^}]+\}|&(?:#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z]+);"#
        let markup = try NSRegularExpression(pattern: kind == .srt ? #"<[^>]+>|"# + otherMarkup : otherMarkup)
        var result: [Int] = []
        while cursor < lines.count {
            if blank(lines[cursor].text) {
                cursor += 1
                continue
            }
            let first = cursor
            while cursor < lines.count, !blank(lines[cursor].text) { cursor += 1 }
            let marker = lines[first].text
            if kind == .vtt, marker == "NOTE" || marker.hasPrefix("NOTE ") || marker.hasPrefix("NOTE\t")
                || marker == "STYLE" || marker == "REGION" { continue }
            let line = first + (marker.contains("-->") ? 0 : 1)
            guard line < cursor else { throw ToolError.invalid("Missing cue timing at line \(first + 1).") }
            let timingText = lines[line].text
            let timingRange = NSRange(timingText.startIndex..., in: timingText)
            guard let match = timing.firstMatch(in: timingText, range: timingRange),
                  let startRange = Range(match.range(at: 1), in: timingText),
                  let endRange = Range(match.range(at: 2), in: timingText),
                  let startTime = seconds(timingText[startRange]), let endTime = seconds(timingText[endRange]),
                  startTime < endTime, line + 1 < cursor else {
                throw ToolError.invalid("Invalid or empty subtitle cue at line \(line + 1).")
            }
            for index in (line + 1)..<cursor {
                let dialogue = lines[index].text
                guard !dialogue.contains("-->"),
                      markup.firstMatch(in: dialogue, range: NSRange(dialogue.startIndex..., in: dialogue)) == nil else {
                    throw ToolError.invalid("Unsupported inline subtitle markup or missing cue separator at line \(index + 1).")
                }
                result.append(index)
            }
        }
        return result
    }

    private static func webVTTMarkup(in line: String, number: Int) throws -> [Substring] {
        let scalars = line.unicodeScalars
        var tags: [Substring] = []
        var cursor = scalars.startIndex
        while let start = scalars[cursor...].firstIndex(of: "<") {
            let end = scalars[start...].firstIndex(of: ">").map { scalars.index(after: $0) } ?? scalars.endIndex
            let tag = line[start..<end]
            let candidate = String(tag)
            guard webVTTInlineMarkup.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil else {
                throw ToolError.invalid("Unsupported WebVTT markup at line \(number).")
            }
            tags.append(tag)
            cursor = end
        }
        return tags
    }

    private static func webVTTDialogue(in line: String, between tags: [Substring]) -> [Range<String.Index>?] {
        func rangeOfDialogue(_ text: Substring) -> Range<String.Index>? {
            guard let first = text.firstIndex(where: { !$0.isWhitespace }),
                  let last = text.lastIndex(where: { !$0.isWhitespace }) else { return nil }
            return first..<text.index(after: last)
        }
        var ranges: [Range<String.Index>?] = []
        var cursor = line.startIndex
        for tag in tags {
            ranges.append(rangeOfDialogue(line[cursor..<tag.startIndex]))
            cursor = tag.endIndex
        }
        ranges.append(rangeOfDialogue(line[cursor...]))
        return ranges
    }

    private static func seconds(_ text: Substring) -> Double? {
        let parts = text.split(separator: ":")
        let converted = parts.map { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard converted.allSatisfy({ $0?.isFinite == true }) else { return nil }
        let value = converted.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return value.isFinite ? value : nil
    }

    private static func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
}
