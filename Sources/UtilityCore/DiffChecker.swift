import Foundation

public enum DiffChecker {
    public static let maximumTextBytes = 2 * 1024 * 1024
    public static let maximumLines = 25_000

    public struct Options: Sendable {
        public var ignoreWhitespace: Bool
        public var ignoreCase: Bool
        public var ignoreBlankLines: Bool

        public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false, ignoreBlankLines: Bool = false) {
            self.ignoreWhitespace = ignoreWhitespace
            self.ignoreCase = ignoreCase
            self.ignoreBlankLines = ignoreBlankLines
        }
    }

    public enum InputError: LocalizedError {
        case tooManyBytes
        case tooManyLines
        case unsupportedEncoding
        case invalidFile

        public var errorDescription: String? {
            switch self {
            case .tooManyBytes: "Each input must be 2 MiB or smaller."
            case .tooManyLines: "Each input must have at most 25,000 lines."
            case .unsupportedEncoding: "Use UTF-8 or UTF-16/UTF-32 with a byte order mark."
            case .invalidFile: "Choose a local plain-text file."
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

    public static func loadText(_ input: URL) async throws -> String {
        let data: Data
        do {
            data = try await PlainTextDecoding.loadVerifiedBytes(input, maximumBytes: maximumTextBytes)
        } catch PlainTextDecoding.ReadIssue.tooLarge {
            throw InputError.tooManyBytes
        } catch PlainTextDecoding.ReadIssue.notRegular, PlainTextDecoding.ReadIssue.nonLocal {
            throw InputError.invalidFile
        }
        guard let text = PlainTextDecoding.decode(data) else { throw InputError.unsupportedEncoding }
        guard text.utf8.count <= maximumTextBytes else { throw InputError.tooManyBytes }
        return text
    }

    public static func compare(_ original: String, _ modified: String, options: Options = .init()) throws -> Result {
        guard original.utf8.count <= maximumTextBytes, modified.utf8.count <= maximumTextBytes else {
            throw InputError.tooManyBytes
        }
        let before = try numberedLines(original, ignoreBlankLines: options.ignoreBlankLines)
        let after = try numberedLines(modified, ignoreBlankLines: options.ignoreBlankLines)
        try Task.checkCancellation()

        let beforeKeys = before.map { key($0.text, options: options) }
        let afterKeys = after.map { key($0.text, options: options) }
        let lineChanges = try lineChanges(beforeKeys, afterKeys)
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
                        segments = changedWords(originalText.text, modifiedText.text, options: options)
                    }
                    rows.append(Row(
                        original: originalText.map { Line(number: $0.number, text: $0.text, segments: segments.0) },
                        modified: modifiedText.map { Line(number: $0.number, text: $0.text, segments: segments.1) },
                        changed: true
                    ))
                }
            }
            if left < before.count, right < after.count {
                rows.append(Row(
                    original: before[left],
                    modified: after[right],
                    changed: false
                ))
                left += 1
                right += 1
            }
        }
        return Result(rows: rows, changeStarts: changeStarts, usedCoarseAlignment: lineChanges.coarse)
    }

    private static func numberedLines(_ text: String, ignoreBlankLines: Bool) throws -> [Line] {
        guard !text.isEmpty else { return [] }
        let lines = text.split(maxSplits: maximumLines, omittingEmptySubsequences: false, whereSeparator: {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        })
        guard lines.count <= maximumLines else { throw InputError.tooManyLines }
        var result: [Line] = []
        for (index, line) in lines.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            if ignoreBlankLines, line.allSatisfy(\.isWhitespace) { continue }
            result.append(Line(number: index + 1, text: String(line), segments: []))
        }
        if ignoreBlankLines, let lastContent = result.last, lastContent.number < lines.count {
            // Keep the break immediately after the last nonblank line.
            result.append(Line(number: lastContent.number + 1, text: "", segments: []))
        }
        return result
    }

    private static func key(_ text: String, options: Options) -> Data {
        let whitespaceAdjusted = options.ignoreWhitespace ? String(text.filter { !$0.isWhitespace }) : text
        let adjusted = options.ignoreCase ? whitespaceAdjusted.folding(
            options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")
        ) : whitespaceAdjusted
        return Data(adjusted.utf8)
    }

    private struct LineSpan {
        var left: Range<Int>
        var right: Range<Int>
        let depth: Int
    }

    private struct LineAnchor {
        let left: Int
        let right: Int
        let unique: Bool
    }

    private struct AnchorChain {
        let end: Int
        let length: Int
        let unique: Int

        func precedes(_ other: Self) -> Bool {
            length < other.length || (length == other.length && unique < other.unique)
        }
    }

    // Like Git's patience diff, anchor shared lines in increasing order.
    // Include repeated occurrences so a rare moved line cannot mask a long match.
    private static func lineChanges(
        _ lhs: [Data], _ rhs: [Data]
    ) throws -> (removals: Set<Int>, insertions: Set<Int>, coarse: Bool) {
        var pending = [LineSpan(left: lhs.indices, right: rhs.indices, depth: 0)]
        var budget = 1_000_000
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        var coarse = false
        while var span = pending.popLast() {
            try Task.checkCancellation()
            while !span.left.isEmpty, !span.right.isEmpty,
                  lhs[span.left.lowerBound] == rhs[span.right.lowerBound] {
                span.left = span.left.dropFirst()
                span.right = span.right.dropFirst()
            }
            while !span.left.isEmpty, !span.right.isEmpty,
                  lhs[span.left.upperBound - 1] == rhs[span.right.upperBound - 1] {
                span.left = span.left.dropLast()
                span.right = span.right.dropLast()
            }
            if span.left.isEmpty || span.right.isEmpty {
                removals.formUnion(span.left)
                insertions.formUnion(span.right)
                continue
            }
            if span.left.count == 1 {
                let match = try firstMatch(lhs[span.left.lowerBound], in: rhs, range: span.right)
                if match == nil { removals.formUnion(span.left) }
                insertions.formUnion(span.right.lazy.filter { $0 != match })
                continue
            }
            if span.right.count == 1 {
                let match = try firstMatch(rhs[span.right.lowerBound], in: lhs, range: span.left)
                if match == nil { insertions.formUnion(span.right) }
                removals.formUnion(span.left.lazy.filter { $0 != match })
                continue
            }
            let work = span.left.count * span.right.count
            if work <= budget {
                budget -= work
                let diff = rhs[span.right].difference(from: lhs[span.left])
                for case .remove(let index, _, _) in diff.removals {
                    removals.insert(span.left.lowerBound + index)
                }
                for case .insert(let index, _, _) in diff.insertions {
                    insertions.insert(span.right.lowerBound + index)
                }
                continue
            }
            let anchors = span.depth < 16 ? try sharedAnchors(lhs, rhs, span: span) : []
            guard !anchors.isEmpty else {
                removals.formUnion(span.left)
                insertions.formUnion(span.right)
                coarse = true
                continue
            }
            var left = span.left.lowerBound
            var right = span.right.lowerBound
            var gaps: [LineSpan] = []
            for anchor in anchors {
                if left < anchor.left || right < anchor.right {
                    gaps.append(LineSpan(left: left..<anchor.left, right: right..<anchor.right, depth: span.depth + 1))
                }
                left = anchor.left + 1
                right = anchor.right + 1
            }
            if left < span.left.upperBound || right < span.right.upperBound {
                gaps.append(LineSpan(left: left..<span.left.upperBound, right: right..<span.right.upperBound, depth: span.depth + 1))
            }
            pending.append(contentsOf: gaps.reversed())
        }
        return (removals, insertions, coarse)
    }

    private static func firstMatch(_ line: Data, in lines: [Data], range: Range<Int>) throws -> Int? {
        for index in range {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            if lines[index] == line { return index }
        }
        return nil
    }

    private static func sharedAnchors(_ lhs: [Data], _ rhs: [Data], span: LineSpan) throws -> [LineAnchor] {
        var left: [Data: [Int]] = [:]
        var right: [Data: [Int]] = [:]
        for index in span.left {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            left[lhs[index], default: []].append(index)
        }
        for index in span.right {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            right[rhs[index], default: []].append(index)
        }

        // Pair repeated lines by occurrence order instead of building every
        // possible pair. A moved unique line must not outrank a longer run.
        var candidates: [LineAnchor] = []
        for (key, indices) in left {
            guard let matches = right[key] else { continue }
            let unique = indices.count == 1 && matches.count == 1
            for (left, right) in zip(indices, matches) {
                candidates.append(LineAnchor(left: left, right: right, unique: unique))
            }
        }
        return try increasingAnchors(candidates.sorted { $0.left < $1.left }, rightSpan: span.right)
    }

    private static func increasingAnchors(_ candidates: [LineAnchor], rightSpan: Range<Int>) throws -> [LineAnchor] {
        guard !candidates.isEmpty else { return [] }
        let empty = AnchorChain(end: -1, length: 0, unique: 0)
        // A Fenwick tree stores the best increasing chain ending below each
        // right-side index. Prefer more unique anchors only for equal lengths.
        var chains = Array(repeating: empty, count: rightSpan.count + 1)
        var best = empty
        var previous = Array(repeating: -1, count: candidates.count)
        for (index, anchor) in candidates.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            let coordinate = anchor.right - rightSpan.lowerBound + 1
            var prefix = coordinate - 1
            var prior = empty
            while prefix > 0 {
                if prior.precedes(chains[prefix]) { prior = chains[prefix] }
                prefix -= prefix & -prefix
            }
            previous[index] = prior.end
            let chain = AnchorChain(end: index, length: prior.length + 1, unique: prior.unique + (anchor.unique ? 1 : 0))
            if best.precedes(chain) { best = chain }
            var position = coordinate
            while position < chains.count {
                if chains[position].precedes(chain) { chains[position] = chain }
                position += position & -position
            }
        }
        var result: [LineAnchor] = []
        var index = best.end
        while index >= 0 {
            result.append(candidates[index])
            index = previous[index]
        }
        return result.reversed()
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
