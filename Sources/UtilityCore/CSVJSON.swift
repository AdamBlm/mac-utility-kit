import Foundation

public enum CSVJSON {
    public static let maximumInputBytes = 2 * 1024 * 1024
    private static let maximumCells = 200_000

    public enum Direction: String, CaseIterable, Identifiable, Sendable {
        case csvToJSON = "CSV → JSON"
        case jsonToCSV = "JSON → CSV"
        case csvToMarkdown = "CSV → Markdown"

        public var id: Self { self }
        public var fileExtension: String {
            switch self {
            case .csvToJSON: "json"
            case .jsonToCSV: "csv"
            case .csvToMarkdown: "md"
            }
        }
    }

    public enum Delimiter: String, CaseIterable, Identifiable, Sendable {
        case comma = "Comma"
        case semicolon = "Semicolon"
        case tab = "Tab"
        case pipe = "Pipe"

        public var id: Self { self }

        fileprivate var byte: UInt8 {
            switch self {
            case .comma: 44
            case .semicolon: 59
            case .tab: 9
            case .pipe: 124
            }
        }
    }

    public struct Result: Sendable {
        public let output: String
        public let columns: [String]
        public let rows: [[String]]
    }

    public enum DelimiterDetection: Equatable, Sendable {
        case detected(Delimiter)
        case ambiguous([Delimiter])
        case unavailable
    }

    public struct Issue: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    package static func loadUTF8(_ input: URL) async throws -> String {
        do {
            let bytes = try await PlainTextDecoding.loadVerifiedBytes(input, maximumBytes: maximumInputBytes)
            guard let text = String(validating: bytes, as: UTF8.self) else {
                throw Issue(message: "This file contains invalid UTF-8.")
            }
            return text
        } catch PlainTextDecoding.ReadIssue.tooLarge {
            throw Issue(message: "Input must be 2 MiB or smaller.")
        } catch let issue as PlainTextDecoding.ReadIssue {
            throw Issue(message: issue.localizedDescription)
        }
    }

    public static func detectDelimiter(_ input: String) throws -> DelimiterDetection {
        guard input.utf8.count <= maximumInputBytes else {
            throw Issue(message: "Input must be 2 MiB or smaller.")
        }
        let bytes = Array(input.utf8)
        var matches: [Delimiter] = []
        for delimiter in Delimiter.allCases {
            try Task.checkCancellation()
            var parser = Reader(bytes: bytes, delimiter: delimiter.byte)
            do {
                let rows = try parser.parse()
                if rows.count > 1, (rows.first?.count ?? 0) > 1 { matches.append(delimiter) }
            } catch is Issue {
                continue
            }
        }
        switch matches.count {
        case 0: return .unavailable
        case 1: return .detected(matches[0])
        default: return .ambiguous(matches)
        }
    }

    public static func convert(
        _ input: String, direction: Direction, delimiter: Delimiter = .comma, includesHeader: Bool = true
    ) throws -> Result {
        guard input.utf8.count <= maximumInputBytes else {
            throw Issue(message: "Input must be 2 MiB or smaller.")
        }

        switch direction {
        case .csvToJSON, .csvToMarkdown:
            var parser = Reader(bytes: Array(input.utf8), delimiter: delimiter.byte)
            let parsed = try parser.parse()
            let width = parsed.first?.count ?? 0
            let headers = includesHeader ? (parsed.first ?? []) : columnNames(width)
            let rows = includesHeader ? Array(parsed.dropFirst()) : parsed
            let output = if direction == .csvToJSON {
                try json(rows, keys: includesHeader ? headers : nil)
            } else {
                try markdown(headers, rows)
            }
            return Result(output: output, columns: headers, rows: rows)
        case .jsonToCSV:
            let json = input.unicodeScalars.first == "\u{FEFF}"
                ? String(String.UnicodeScalarView(input.unicodeScalars.dropFirst())) : input
            let (headers, rows) = try jsonTable(json)
            let output = try csv(includesHeader && !headers.isEmpty ? [headers] + rows : rows, delimiter: delimiter)
            return Result(output: output, columns: headers, rows: rows)
        }
    }

    private static func columnNames(_ count: Int) -> [String] {
        (0 ..< count).map { "Column \($0 + 1)" }
    }

    private static func json(_ rows: [[String]], keys: [String]?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quoted(_ text: String) throws -> String {
            String(decoding: try encoder.encode(text), as: UTF8.self)
        }
        if let keys {
            var unique: Set<Data> = []
            for (index, key) in keys.enumerated() where !unique.insert(Data(key.utf8)).inserted {
                throw Issue(message: "Duplicate header \(key.debugDescription) in field \(index + 1).")
            }
        }
        guard !rows.isEmpty else { return "[]" }
        let quotedKeys = try keys?.map(quoted)
        var output = "["
        for (index, row) in rows.enumerated() {
            try Task.checkCancellation()
            output += index == 0 ? "\n  " : ",\n  "
            let values = try row.map(quoted)
            if let quotedKeys {
                output += "{" + zip(quotedKeys, values).map { $0 + ": " + $1 }.joined(separator: ", ") + "}"
            } else {
                output += "[" + values.joined(separator: ", ") + "]"
            }
        }
        return output + "\n]"
    }

    private static func jsonTable(_ input: String) throws -> ([String], [[String]]) {
        guard case .array(let nodes) = try JSONFormatter.parsedValue(input) else {
            throw Issue(message: "JSON must contain an array of objects or arrays.")
        }
        guard let first = nodes.first else { return ([], []) }
        var rows: [[String]] = []
        switch first {
        case .array(let firstRow):
            let count = firstRow.count
            try validateDimensions(rows: nodes.count, columns: count)
            for (index, node) in nodes.enumerated() {
                try Task.checkCancellation()
                guard case .array(let fields) = node else {
                    throw Issue(message: "JSON row \(index + 1) must be an array.")
                }
                guard fields.count == count else {
                    throw widthIssue(index + 1, actual: fields.count, expected: count)
                }
                rows.append(try fields.enumerated().map {
                    try cell($0.element, row: index + 1, field: String($0.offset + 1))
                })
            }
            return (columnNames(count), rows)
        case .object(let firstRow):
            let keys = firstRow.map { Data($0.key) }
            let names = firstRow.map { String(decoding: $0.key, as: UTF8.self) }
            try validateDimensions(rows: nodes.count, columns: keys.count)
            let expected = Set(keys)
            for (index, node) in nodes.enumerated() {
                try Task.checkCancellation()
                guard case .object(let fields) = node else {
                    throw Issue(message: "JSON row \(index + 1) must be an object.")
                }
                var values: [Data: String] = [:]
                for field in fields {
                    let key = Data(field.key)
                    let name = String(decoding: key, as: UTF8.self).debugDescription
                    guard expected.contains(key) else {
                        throw Issue(message: "Unexpected field \(name) in JSON row \(index + 1).")
                    }
                    guard values[key] == nil else {
                        throw Issue(message: "Duplicate field \(name) in JSON row \(index + 1).")
                    }
                    values[key] = try cell(field.value, row: index + 1, field: name)
                }
                rows.append(try zip(keys, names).map { key, name in
                    guard let value = values[key] else {
                        throw Issue(message: "JSON row \(index + 1) is missing field \(name.debugDescription).")
                    }
                    return value
                })
            }
            return (names, rows)
        default:
            throw Issue(message: "JSON row 1 must be an object or array.")
        }
    }

    private static func validateDimensions(rows: Int, columns: Int) throws {
        guard columns > 0 else { throw Issue(message: "JSON rows must contain at least one field.") }
        guard rows <= maximumCells / columns else { throw Issue(message: "The table exceeds 200,000 cells.") }
    }

    private static func cell(_ node: JSONNode, row: Int, field: String) throws -> String {
        guard case .token(let token) = node else {
            throw Issue(message: "Nested value in JSON row \(row), field \(field).")
        }
        if token == "null" { return "" }
        if token.utf8.first == 34 {
            return try JSONDecoder().decode(String.self, from: Data(token.utf8))
        }
        return token
    }

    private static func csv(_ rows: [[String]], delimiter: Delimiter) throws -> String {
        let separator = String(Unicode.Scalar(delimiter.byte))
        var output = ""
        for row in rows {
            try Task.checkCancellation()
            let isFirstRow = output.isEmpty
            output += row.enumerated().map { column, value in
                // A literal U+FEFF at byte zero would be read as the file BOM.
                let startsWithBOM = isFirstRow && column == 0 && value.unicodeScalars.first == "\u{FEFF}"
                let needsQuotes = startsWithBOM || value.isEmpty || value.utf8.contains {
                    $0 == 34 || $0 == 10 || $0 == 13 || $0 == delimiter.byte
                }
                if !needsQuotes { return value }
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: separator) + "\r\n"
        }
        return output
    }

    private static func markdown(_ headers: [String], _ rows: [[String]]) throws -> String {
        guard !headers.isEmpty else { return "" }
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |\n" }
        var output = row(headers.map(escapedMarkdownCell)) + row(headers.map { _ in "---" })
        for cells in rows {
            try Task.checkCancellation()
            output += row(cells.map(escapedMarkdownCell))
        }
        return output
    }

    private static func escapedMarkdownCell(_ value: String) -> String {
        let text = value.replacingOccurrences(of: "\r\n", with: "\n")
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 10, 13:
                escaped += "&#10;"
            case 9, 32...47, 58...64, 91...96, 123...126:
                escaped += "&#\(scalar.value);"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func widthIssue(_ row: Int, actual: Int, expected: Int) -> Issue {
        Issue(message: "Row \(row) has \(actual) fields. Expected \(expected).")
    }

    // RFC 4180 field states. LF and bare CR also delimit records outside quotes.
    private struct Reader {
        private enum State { case fieldStart, unquoted, quoted, afterQuote }

        private let bytes: [UInt8]
        private let delimiter: UInt8
        private var offset = 0
        private var state = State.fieldStart
        private var field: [UInt8] = []
        private var row: [String] = []
        private var rows: [[String]] = []
        private var cellCount = 0

        init(bytes: [UInt8], delimiter: UInt8) {
            self.bytes = bytes
            self.delimiter = delimiter
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { offset = 3 }
        }

        mutating func parse() throws -> [[String]] {
            while offset < bytes.count {
                if offset.isMultiple(of: 4_096) { try Task.checkCancellation() }
                let byte = bytes[offset]
                offset += 1
                if state == .quoted {
                    if byte == 34 { state = .afterQuote } else { field.append(byte) }
                    continue
                }
                switch byte {
                case 34:
                    switch state {
                    case .fieldStart: state = .quoted
                    case .afterQuote:
                        field.append(byte)
                        state = .quoted
                    default: throw issue("Unexpected quote")
                    }
                case delimiter:
                    try finishField()
                case 10, 13:
                    if byte == 13, offset < bytes.count, bytes[offset] == 10 { offset += 1 }
                    try finishRow()
                default:
                    guard state != .afterQuote else { throw issue("Expected a delimiter after the closing quote") }
                    field.append(byte)
                    state = .unquoted
                }
            }
            guard state != .quoted else { throw issue("Missing closing quote") }
            if state != .fieldStart || !row.isEmpty { try finishRow() }
            return rows
        }

        private mutating func finishField() throws {
            guard cellCount < CSVJSON.maximumCells else { throw Issue(message: "The table exceeds 200,000 cells.") }
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            state = .fieldStart
            cellCount += 1
        }

        private mutating func finishRow() throws {
            try finishField()
            if let first = rows.first, row.count != first.count {
                throw CSVJSON.widthIssue(rows.count + 1, actual: row.count, expected: first.count)
            }
            rows.append(row)
            row = []
        }

        private func issue(_ reason: String) -> Issue {
            Issue(message: "\(reason) in row \(rows.count + 1), field \(row.count + 1).")
        }
    }
}
