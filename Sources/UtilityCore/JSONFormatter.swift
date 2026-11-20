import Foundation

public struct JSONFormatResult: Sendable {
    public let text: String
    public let duplicateOccurrences: [JSONDuplicateKey]
    public var duplicateKeys: [String] { duplicateOccurrences.map(\.key) }
}

public struct JSONDuplicateKey: Equatable, Sendable {
    public let key: String
    public let line: Int
    public let column: Int
}

public struct JSONFormatError: LocalizedError {
    public let message: String
    public let line: Int
    public let column: Int
    let byteOffset: Int
    public var errorDescription: String? { "\(message) (line \(line), column \(column))." }

    package func sourceRange(in text: String) -> Range<String.Index>? {
        guard let byteIndex = text.utf8.index(text.utf8.startIndex, offsetBy: byteOffset, limitedBy: text.utf8.endIndex) else {
            return nil
        }
        if byteIndex == text.utf8.endIndex { return text.endIndex..<text.endIndex }
        // A parse error can be inside a grapheme, for example at a combining mark after a token.
        guard let start = String.Index(byteIndex, within: text) ?? text.indices.last(where: { $0 <= byteIndex }) else {
            return nil
        }
        return start..<text.index(after: start)
    }
}

public enum JSONIndentation: String, CaseIterable, Identifiable, Sendable {
    case twoSpaces = "2 spaces"
    case fourSpaces = "4 spaces"
    case tab = "Tab"
    case minified = "Minified"

    public var id: Self { self }

    fileprivate var whitespace: String? {
        switch self {
        case .twoSpaces: "  "
        case .fourSpaces: "    "
        case .tab: "\t"
        case .minified: nil
        }
    }
}

public enum JSONFormatter {
    package static let maximumInputBytes = 16 * 1024 * 1024

    package static func loadUTF8(_ input: URL) async throws -> String {
        let data: Data
        do {
            data = try await PlainTextDecoding.loadVerifiedBytes(input, maximumBytes: maximumInputBytes)
        } catch PlainTextDecoding.ReadIssue.tooLarge {
            throw ToolError.invalid("Choose a JSON file no larger than 16 MiB.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.invalid("This file contains invalid UTF-8.")
        }
        return text
    }

    static func parsedValue(_ text: String) throws -> JSONNode {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.parse()
    }

    public static func format(
        _ text: String, indentation: JSONIndentation = .twoSpaces, sortKeys: Bool = false
    ) throws -> JSONFormatResult {
        guard text.utf8.count <= maximumInputBytes else {
            throw ToolError.invalid("Enter JSON no larger than 16 MiB.")
        }
        var parser = Parser(bytes: Array(text.utf8))
        let root = try parser.parse()
        var output = ""
        try root.write(to: &output, indentation: indentation.whitespace, sortKeys: sortKeys, depth: 0)
        return JSONFormatResult(text: output, duplicateOccurrences: try parser.duplicateOccurrences())
    }
}

struct JSONMember {
    let rawKey: String
    let key: [UInt8]
    let value: JSONNode
}

enum JSONNode {
    case token(String)
    case array([JSONNode])
    case object([JSONMember])

    fileprivate func write(to output: inout String, indentation: String?, sortKeys: Bool, depth: Int) throws {
        try Task.checkCancellation()
        switch self {
        case .token(let raw): output += raw
        case .array(let elements):
            output += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { output += "," }
                writeBreak(to: &output, indentation: indentation, depth: depth + 1)
                try element.write(to: &output, indentation: indentation, sortKeys: sortKeys, depth: depth + 1)
            }
            if !elements.isEmpty { writeBreak(to: &output, indentation: indentation, depth: depth) }
            output += "]"
        case .object(let members):
            let ordered = sortKeys ? members.sorted { $0.key.lexicographicallyPrecedes($1.key) } : members
            output += "{"
            for (index, member) in ordered.enumerated() {
                if index > 0 { output += "," }
                writeBreak(to: &output, indentation: indentation, depth: depth + 1)
                output += member.rawKey
                output += indentation == nil ? ":" : ": "
                try member.value.write(to: &output, indentation: indentation, sortKeys: sortKeys, depth: depth + 1)
            }
            if !ordered.isEmpty { writeBreak(to: &output, indentation: indentation, depth: depth) }
            output += "}"
        }
    }

    private func writeBreak(to output: inout String, indentation: String?, depth: Int) {
        if let indentation {
            output += "\n" + String(repeating: indentation, count: depth)
        }
    }
}

private struct Parser {
    let bytes: [UInt8]
    var offset = 0
    private var repeatedKeys: [(key: String, offset: Int)] = []

    init(bytes: [UInt8]) { self.bytes = bytes }

    private var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    func duplicateOccurrences() throws -> [JSONDuplicateKey] {
        var cursor = SourcePositionCursor(bytes: bytes)
        return try repeatedKeys.map { occurrence in
            try cursor.advance(to: occurrence.offset)
            return JSONDuplicateKey(key: occurrence.key, line: cursor.line, column: cursor.column)
        }
    }

    mutating func parse() throws -> JSONNode {
        let root = try value(depth: 0)
        skipWhitespace()
        guard current == nil else { throw error("Unexpected content after the JSON value") }
        return root
    }

    private mutating func value(depth: Int) throws -> JSONNode {
        try Task.checkCancellation()
        guard depth <= 256 else { throw error("JSON exceeds the supported nesting depth of 256") }
        skipWhitespace()
        switch current {
        case 123: return try object(depth: depth)
        case 91: return try array(depth: depth)
        case 34: return .token(try string().raw)
        case 116: return try literal("true")
        case 102: return try literal("false")
        case 110: return try literal("null")
        case 45, 48...57: return .token(try number())
        default: throw error("Expected a JSON value")
        }
    }

    private mutating func object(depth: Int) throws -> JSONNode {
        offset += 1
        skipWhitespace()
        if consume(125) { return .object([]) }
        var members = [JSONMember]()
        var seen = Set<[UInt8]>()
        repeat {
            skipWhitespace()
            guard current == 34 else { throw error("Expected an object key in double quotes") }
            let keyOffset = offset
            let (raw, decoded) = try string()
            let key = Array(decoded.utf8)
            if !seen.insert(key).inserted { repeatedKeys.append((decoded, keyOffset)) }
            skipWhitespace()
            guard consume(58) else { throw error("Expected a colon after the object key") }
            members.append(JSONMember(rawKey: raw, key: key, value: try value(depth: depth + 1)))
            skipWhitespace()
        } while consume(44)
        guard consume(125) else { throw error("Expected a comma or closing brace") }
        return .object(members)
    }

    private mutating func array(depth: Int) throws -> JSONNode {
        offset += 1
        skipWhitespace()
        if consume(93) { return .array([]) }
        var elements = [JSONNode]()
        repeat {
            elements.append(try value(depth: depth + 1))
            skipWhitespace()
        } while consume(44)
        guard consume(93) else { throw error("Expected a comma or closing bracket") }
        return .array(elements)
    }

    private mutating func string() throws -> (raw: String, decoded: String) {
        let start = offset
        offset += 1
        while let byte = current {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            if consume(34) {
                let token = bytes[start..<offset]
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(token)) else {
                    throw error("Invalid Unicode escape in string", at: start)
                }
                return (String(decoding: token, as: UTF8.self), decoded)
            }
            guard byte >= 32 else { throw error("Unescaped control character in string") }
            if consume(92) {
                if consume(117) {
                    for _ in 0..<4 {
                        switch current {
                        case 48...57, 65...70, 97...102: offset += 1
                        default: throw error("Expected four hexadecimal digits after a Unicode escape")
                        }
                    }
                } else {
                    switch current {
                    case 34, 47, 92, 98, 102, 110, 114, 116: offset += 1
                    default: throw error("Invalid escape in string")
                    }
                }
            } else {
                offset += 1
            }
        }
        throw error("Unterminated string")
    }

    private mutating func literal(_ word: String) throws -> JSONNode {
        for byte in word.utf8 {
            guard consume(byte) else { throw error("Expected \(word)") }
        }
        return .token(word)
    }

    private mutating func number() throws -> String {
        let start = offset
        _ = consume(45)
        if consume(48) {
            if isDigit { throw error("Leading zeros are not allowed in numbers") }
        } else {
            try digits()
        }
        if consume(46) { try digits() }
        if consume(101) || consume(69) {
            _ = consume(43) || consume(45)
            try digits()
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private var isDigit: Bool {
        guard let current else { return false }
        return (48...57).contains(current)
    }

    private mutating func digits() throws {
        guard isDigit else { throw error("Expected a digit") }
        repeat { offset += 1 } while isDigit
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        offset += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 9 || byte == 10 || byte == 13 || byte == 32 {
            offset += 1
        }
    }

    private func error(_ message: String, at index: Int? = nil) -> JSONFormatError {
        let byteOffset = index ?? offset
        let prefix = String(decoding: bytes.prefix(byteOffset), as: UTF8.self)
        // JSON recognizes only CR and LF as line breaks. Swift groups CRLF as one Character.
        let lineEndings: Set<Character> = ["\r", "\n", "\r\n"]
        let lineCount = prefix.filter { lineEndings.contains($0) }.count
        let column = prefix.reversed().prefix { !lineEndings.contains($0) }.count + 1
        return JSONFormatError(message: message, line: lineCount + 1, column: column, byteOffset: byteOffset)
    }
}

private struct SourcePositionCursor {
    let bytes: [UInt8]
    private(set) var line = 1
    private(set) var column = 1
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func advance(to target: Int) throws {
        try Task.checkCancellation()
        var chunkStart = offset
        while offset < target {
            if offset.isMultiple(of: 4_096) { try Task.checkCancellation() }
            let byte = bytes[offset]
            offset += 1
            if byte == 13 || byte == 10 {
                if byte == 13 && offset < target && bytes[offset] == 10 { offset += 1 }
                line += 1
                column = 1
                chunkStart = offset
            }
        }
        // Key offsets begin at a quote following syntax or whitespace, at a grapheme boundary.
        column += String(decoding: bytes[chunkStart..<target], as: UTF8.self).count
    }
}

private func ~= (pattern: ClosedRange<UInt8>, value: UInt8?) -> Bool {
    value.map { pattern.contains($0) } ?? false
}
