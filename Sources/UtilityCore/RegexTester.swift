import CSystemRegex
import Foundation

public struct RegexTesterOptions: Equatable, Sendable {
    public var ignoresCase = false
    public var multiline = false
    public var dotMatchesNewlines = false

    public init() {}
}

public enum RegexTester {
    public struct Capture: Equatable, Identifiable, Sendable {
        public let id: Int
        public let name: String?
        public let text: String?
        public let range: Range<Int>?
    }

    public struct Match: Equatable, Identifiable, Sendable {
        public let id: Int
        public let captures: [Capture]
    }

    public struct Evaluation: Equatable, Sendable {
        public let matches: [Match]
        public let replacement: String?
    }

    public static func evaluate(
        pattern: String, sample: String, replacement: String? = nil, options: RegexTesterOptions = .init()
    ) throws -> Evaluation {
        try Task.checkCancellation()
        guard pattern.utf16.count <= 4_096, sample.utf16.count <= 262_144,
              (replacement?.utf16.count ?? 0) <= 4_096 else {
            throw ToolError.invalid("Use up to 4,096 UTF-16 units in the pattern and replacement and 262,144 in the sample.")
        }
        var status: Int32 = 0
        var flags: UInt32 = 0
        if options.ignoresCase { flags |= UInt32(MUKRegexCaseInsensitive) }
        if options.multiline { flags |= UInt32(MUKRegexMultiline) }
        if options.dotMatchesNewlines { flags |= UInt32(MUKRegexDotAll) }
        let patternUnits = Array((pattern.isEmpty ? "(?:)" : pattern).utf16) + [0]
        var parseError = UParseError()
        guard let regex = patternUnits.withUnsafeBufferPointer({
            uregex_open($0.baseAddress, Int32($0.count - 1), flags, &parseError, &status)
        }) else {
            throw failure(status, context: "Pattern error at UTF-16 offset \(parseError.offset)")
        }
        defer { uregex_close(regex) }
        try check(status)
        uregex_setTimeLimit(regex, 35, &status)
        uregex_setStackLimit(regex, 2 * 1024 * 1024, &status)
        let count = Int(uregex_groupCount(regex, &status))
        try check(status)
        guard count <= 64 else { throw ToolError.invalid("Use up to 64 capture groups.") }
        let names = groupNames(in: pattern, regex: regex)
        let template = try replacement.map { try parseReplacement($0, groups: count, names: names) }

        let sampleUnits = Array(sample.utf16) + [0]
        return try sampleUnits.withUnsafeBufferPointer { buffer in
            let length = buffer.count - 1
            uregex_setText(regex, buffer.baseAddress, Int32(length), &status)
            try check(status)
            let deadline = ContinuousClock.now + .seconds(1)
            var matches: [Match] = []
            var result: [UInt16] = []
            var copiedThrough = 0
            while uregex_findNext(regex, &status) != 0 {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline, matches.count < 2_000 else {
                    throw ToolError.invalid("The match limit was reached. Use a shorter sample or a more selective pattern.")
                }
                var captures: [Capture] = []
                for group in 0...count {
                    let start = Int(uregex_start(regex, Int32(group), &status))
                    let end = Int(uregex_end(regex, Int32(group), &status))
                    try check(status)
                    let range = start >= 0 ? start..<end : nil
                    let preview = range.map { String(decoding: buffer[$0].prefix(256), as: UTF16.self) + ($0.count > 256 ? "…" : "") }
                    captures.append(Capture(id: group, name: names[group], text: preview, range: range))
                }
                if let template, let overall = captures[0].range {
                    result.append(contentsOf: buffer[copiedThrough..<overall.lowerBound])
                    for piece in template {
                        switch piece {
                        case .literal(let text): result.append(contentsOf: text.utf16)
                        case .group(let group):
                            if let range = captures[group].range { result.append(contentsOf: buffer[range]) }
                        }
                        try checkOutput(result.count)
                    }
                    copiedThrough = overall.upperBound
                }
                matches.append(Match(id: matches.count, captures: captures))
            }
            try check(status)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ToolError.invalid("The match time limit was reached.") }
            if template != nil {
                result.append(contentsOf: buffer[copiedThrough..<length])
                try checkOutput(result.count)
            }
            return Evaluation(matches: matches, replacement: template == nil ? nil : String(decoding: result, as: UTF16.self))
        }
    }

    private enum ReplacementPart {
        case literal(String)
        case group(Int)
    }

    private static func parseReplacement(_ replacement: String, groups: Int, names: [Int: String]) throws -> [ReplacementPart] {
        var parts: [ReplacementPart] = []
        var literal = ""
        var index = replacement.startIndex
        func next() -> Character? {
            guard index < replacement.endIndex else { return nil }
            defer { replacement.formIndex(after: &index) }
            return replacement[index]
        }
        while let char = next() {
            switch char {
            case "\\":
                guard let escaped = next() else { throw ToolError.invalid("Finish the replacement escape after the backslash.") }
                literal.append(escaped)
            case "$":
                if !literal.isEmpty {
                    parts.append(.literal(literal))
                    literal = ""
                }
                var group: Int?
                if index < replacement.endIndex, replacement[index] == "{" {
                    _ = next()
                    let start = index
                    guard let end = replacement[start...].firstIndex(of: "}") else {
                        throw ToolError.invalid("Close the named group reference with }.")
                    }
                    group = names.first { $0.value == replacement[start..<end] }?.key
                    index = replacement.index(after: end)
                } else {
                    while index < replacement.endIndex, let digit = replacement[index].asciiValue,
                          (48...57).contains(digit) {
                        let candidate = (group ?? 0) * 10 + Int(digit - 48)
                        guard candidate <= groups else { break }
                        group = candidate
                        _ = next()
                    }
                }
                guard let group else { throw ToolError.invalid("The replacement refers to an unknown capture group.") }
                parts.append(.group(group))
            default: literal.append(char)
            }
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        return parts
    }

    private static func groupNames(in pattern: String, regex: OpaquePointer) -> [Int: String] {
        var values: [Int: String] = [:]
        for candidate in pattern.matches(of: /\(\?<([A-Za-z][A-Za-z0-9]*)>/) {
            let name = String(candidate.1)
            var status: Int32 = 0
            let number = name.withCString { uregex_groupNumberFromCName(regex, $0, Int32(name.utf8.count), &status) }
            if status <= 0, number > 0 { values[Int(number)] = name }
        }
        return values
    }

    private static func checkOutput(_ count: Int) throws {
        guard count <= 1_048_576 else { throw ToolError.invalid("The replacement exceeds one million UTF-16 units.") }
    }

    private static func check(_ status: Int32) throws {
        if status > 0 { throw failure(status, context: "Regex error") }
    }

    private static func failure(_ status: Int32, context: String) -> ToolError {
        let reason = u_errorName(status).map { String(cString: $0) } ?? String(status)
        if reason == "U_REGEX_TIME_OUT" || reason == "U_REGEX_STACK_OVERFLOW" {
            return .invalid("The pattern reached the regex time or memory limit.")
        }
        return .invalid("\(context): \(reason).")
    }
}
