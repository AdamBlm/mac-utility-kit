import Foundation

public enum TextCase: String, CaseIterable, Identifiable, Sendable {
    case uppercase = "UPPERCASE"
    case lowercase = "lowercase"
    case title = "Title Case"
    case sentence = "Sentence case"
    case camel = "camelCase"
    case snake = "snake_case"
    case kebab = "kebab-case"

    public var id: Self { self }
}

public enum CaseConverter {
    public static func lineSelection(in text: String, for ranges: [Range<String.Index>]) throws -> String {
        guard text.utf8.count <= 2_097_152 else { throw ToolError.invalid("Enter up to 2 MB of text.") }
        var lineStarts = [text.startIndex]
        for index in text.indices where text[index].isNewline {
            lineStarts.append(text.index(after: index))
        }

        func line(at index: String.Index, includingBoundary: Bool) -> Int {
            var lower = 0
            var upper = lineStarts.count
            while lower < upper {
                let mid = lower + (upper - lower) / 2
                if lineStarts[mid] < index || (includingBoundary && lineStarts[mid] == index) {
                    lower = mid + 1
                } else {
                    upper = mid
                }
            }
            return lower
        }

        var lines = IndexSet()
        for range in ranges where !range.isEmpty && range.lowerBound >= text.startIndex && range.upperBound <= text.endIndex {
            let first = line(at: range.lowerBound, includingBoundary: true)
            let last = line(at: range.upperBound, includingBoundary: false)
            lines.insert(integersIn: first..<(last + 1))
        }
        return lines.rangeView.map { range in
            range.count == 1 ? String(range.lowerBound) : "\(range.lowerBound)–\(range.upperBound - 1)"
        }.joined(separator: ", ")
    }

    public static func convert(
        _ text: String, to style: TextCase, locale: Locale = .current, selectedLines: String? = nil
    ) throws -> String {
        guard text.utf8.count <= 2_097_152 else {
            throw ToolError.invalid("Enter up to 2 MB of text.")
        }
        guard let selectedLines else { return apply(text, style: style, locale: locale) }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let breaks = text.filter(\.isNewline)
        let selected = try Set(PageSelection.indices(selectedLines, pageCount: lines.count))
        var converted = ""
        for (index, lineBreak) in breaks.enumerated() {
            let line = String(lines[index])
            converted += selected.contains(index) ? apply(line, style: style, locale: locale) : line
            converted.append(lineBreak)
        }
        if let last = lines.last {
            let line = String(last)
            converted += selected.contains(lines.count - 1) ? apply(line, style: style, locale: locale) : line
        }
        return converted
    }

    private static func apply(_ input: String, style: TextCase, locale: Locale) -> String {
        switch style {
        case .uppercase: input.uppercased(with: locale)
        case .lowercase: input.lowercased(with: locale)
        case .title: input.capitalized(with: locale)
        case .sentence: sentenceCase(input, locale: locale)
        case .snake: words(input).map { $0.lowercased(with: locale) }.joined(separator: "_")
        case .kebab: words(input).map { $0.lowercased(with: locale) }.joined(separator: "-")
        case .camel:
            words(input).enumerated().map { index, word in
                let lower = word.lowercased(with: locale)
                if index == 0 { return lower }
                // Preserve boundaries that capitalization cannot mark, as in change-case.
                if lower.first?.isNumber == true { return "_" + lower }
                return capitalizingInitial(lower, locale: locale)
            }.joined()
        }
    }

    private static func sentenceCase(_ input: String, locale: Locale) -> String {
        // Whole-context lowercasing keeps language rules such as Greek final sigma.
        let lowered = input.lowercased(with: locale)
        var output = ""
        output.reserveCapacity(lowered.utf8.count)
        var copiedThrough = lowered.startIndex
        lowered.enumerateSubstrings(in: lowered.startIndex..<lowered.endIndex, options: [.bySentences, .substringNotRequired]) {
            _, range, _, _ in
            guard let first = lowered[range].firstIndex(where: \.isLetter) else { return }
            output += lowered[copiedThrough..<first]
            output += String(lowered[first]).uppercased(with: locale)
            copiedThrough = lowered.index(after: first)
        }
        output += lowered[copiedThrough...]
        return output
    }

    private static func capitalizingInitial(_ word: String, locale: Locale) -> String {
        guard let first = word.first else { return word }
        return String(first).uppercased(with: locale) + word.dropFirst()
    }

    private static func words(_ input: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var previous: Character?
        for index in input.indices {
            let current = input[index]
            guard current.isLetter || current.isNumber else {
                if !token.isEmpty { tokens.append(token) }
                token = ""
                previous = nil
                continue
            }
            if let previous, current.isUppercase {
                let next = input.index(after: index)
                let followsAcronym = previous.isUppercase && next < input.endIndex && input[next].isLowercase
                if previous.isLowercase || previous.isNumber || followsAcronym {
                    tokens.append(token)
                    token = ""
                }
            }
            token.append(current)
            previous = current
        }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }
}
