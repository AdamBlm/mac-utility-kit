import Foundation

public enum DiffChecker {
    public static let maximumTextBytes = 2 * 1024 * 1024
    public static let maximumLines = 25_000

    public struct Options: Sendable {
        public var ignoreWhitespace: Bool
        public var ignoreCase: Bool

        public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false) {
            self.ignoreWhitespace = ignoreWhitespace
            self.ignoreCase = ignoreCase
        }
    }

    public enum InputError: LocalizedError {
        case tooManyBytes
        case tooManyLines

        public var errorDescription: String? {
            switch self {
            case .tooManyBytes: "Each input must be 2 MiB or smaller."
            case .tooManyLines: "Each input must have at most 25,000 lines."
            }
        }
    }

    public struct Segment: Sendable {
        public let text: String
        public let changed: Bool
    }

    public struct Line: Sendable {
        public let number: Int
        public let text: String
        public let segments: [Segment]
    }

    public struct Row: Sendable {
        public let original: Line?
        public let modified: Line?
        public let changed: Bool
    }

    public struct Result: Sendable {
        public let rows: [Row]
        public let changeStarts: [Int]
        public let usedCoarseAlignment: Bool
    }

    public static func compare(_ original: String, _ modified: String, options: Options = .init()) throws -> Result {
        guard original.utf8.count <= maximumTextBytes, modified.utf8.count <= maximumTextBytes else {
            throw InputError.tooManyBytes
        }
        let before = lines(original)
        let after = lines(modified)
        guard before.count <= maximumLines, after.count <= maximumLines else { throw InputError.tooManyLines }
        try Task.checkCancellation()

        let beforeKeys = before.map { key($0, options: options) }
        let afterKeys = after.map { key($0, options: options) }
        let lineChanges = changes(beforeKeys, afterKeys, maximumWork: 1_000_000)
        var rows: [Row] = []
        var changeStarts: [Int] = []
        var left = 0
        var right = 0
        while left < before.count || right < after.count {
            try Task.checkCancellation()
            let leftStart = left
            let rightStart = right
            while lineChanges.removals.contains(left) { left += 1 }
            while lineChanges.insertions.contains(right) { right += 1 }
            if left != leftStart || right != rightStart {
                changeStarts.append(rows.count)
                for offset in 0 ..< max(left - leftStart, right - rightStart) {
                    try Task.checkCancellation()
                    let originalIndex = leftStart + offset
                    let modifiedIndex = rightStart + offset
                    let originalText = originalIndex < left ? before[originalIndex] : nil
                    let modifiedText = modifiedIndex < right ? after[modifiedIndex] : nil
                    var segments: ([Segment], [Segment]) = ([], [])
                    if let originalText, let modifiedText {
                        segments = changedWords(originalText, modifiedText, options: options)
                    }
                    rows.append(Row(
                        original: originalText.map { Line(number: originalIndex + 1, text: $0, segments: segments.0) },
                        modified: modifiedText.map { Line(number: modifiedIndex + 1, text: $0, segments: segments.1) },
                        changed: true
                    ))
                }
            }
            if left < before.count, right < after.count {
                rows.append(Row(
                    original: Line(number: left + 1, text: before[left], segments: []),
                    modified: Line(number: right + 1, text: after[right], segments: []),
                    changed: false
                ))
                left += 1
                right += 1
            }
        }
        return Result(rows: rows, changeStarts: changeStarts, usedCoarseAlignment: lineChanges.coarse)
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.split(maxSplits: maximumLines, omittingEmptySubsequences: false, whereSeparator: {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        }).map(String.init)
    }

    private static func key(_ text: String, options: Options) -> Data {
        let whitespaceAdjusted = options.ignoreWhitespace ? String(text.filter { !$0.isWhitespace }) : text
        let adjusted = options.ignoreCase ? whitespaceAdjusted.folding(
            options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")
        ) : whitespaceAdjusted
        return Data(adjusted.utf8)
    }

    private static func changes(
        _ lhs: [Data], _ rhs: [Data], maximumWork: Int
    ) -> (removals: Set<Int>, insertions: Set<Int>, coarse: Bool) {
        var start = 0
        var lhsEnd = lhs.count
        var rhsEnd = rhs.count
        while start < min(lhsEnd, rhsEnd), lhs[start] == rhs[start] { start += 1 }
        while lhsEnd > start, rhsEnd > start, lhs[lhsEnd - 1] == rhs[rhsEnd - 1] {
            lhsEnd -= 1
            rhsEnd -= 1
        }
        let lhsRange = start ..< lhsEnd
        let rhsRange = start ..< rhsEnd
        let approximate = lhsRange.count * rhsRange.count > maximumWork
        if approximate || lhsRange.isEmpty || rhsRange.isEmpty {
            return (Set(lhsRange), Set(rhsRange), approximate)
        }
        let difference = rhs[rhsRange].difference(from: lhs[lhsRange])
        return (
            Set(difference.removals.map { change in
                if case .remove(let offset, _, _) = change { return offset + start }
                preconditionFailure("CollectionDifference removal must contain remove changes")
            }),
            Set(difference.insertions.map { change in
                if case .insert(let offset, _, _) = change { return offset + start }
                preconditionFailure("CollectionDifference insertion must contain insert changes")
            }),
            false
        )
    }

    private enum TokenKind: Equatable { case word, whitespace, symbol }

    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        var previous: TokenKind?
        for index in text.indices {
            let character = text[index]
            let kind: TokenKind = character.isWhitespace ? .whitespace
                : (character.isLetter || character.isNumber || character == "_") ? .word : .symbol
            if index != start, kind != previous || kind == .symbol {
                result.append(String(text[start ..< index]))
                start = index
            }
            previous = kind
        }
        if start != text.endIndex { result.append(String(text[start...])) }
        return result
    }

    private static func changedWords(_ original: String, _ modified: String, options: Options) -> ([Segment], [Segment]) {
        guard original.utf8.count + modified.utf8.count <= 16_384 else { return ([], []) }
        let lhs = tokens(original)
        let rhs = tokens(modified)
        let left = lhs.map { key($0, options: options) }
        let right = rhs.map { key($0, options: options) }
        let leftOffsets = left.indices.filter { !left[$0].isEmpty }
        let rightOffsets = right.indices.filter { !right[$0].isEmpty }
        let diff = changes(leftOffsets.map { left[$0] }, rightOffsets.map { right[$0] }, maximumWork: 32_000)
        guard !diff.coarse else { return ([], []) }

        func marked(_ tokens: [String], changed: Set<Int>) -> [Segment] {
            tokens.enumerated().map { Segment(text: $0.element, changed: changed.contains($0.offset)) }
        }
        return (
            marked(lhs, changed: Set(diff.removals.map { leftOffsets[$0] })),
            marked(rhs, changed: Set(diff.insertions.map { rightOffsets[$0] }))
        )
    }
}
