import Foundation
import NaturalLanguage

public struct WordCounterOptions: Equatable, Sendable {
    public var excludesWhitespace = false
    public var wordsPerMinute = 200

    public init() {}
}

public struct WordFrequency: Equatable, Identifiable, Sendable {
    public let word: String
    public let count: Int

    public var id: String { word }
}

public struct WordCount: Equatable, Sendable {
    public let words: Int
    public let characters: Int
    public let sentences: Int
    public let paragraphs: Int
    public let readingSeconds: Int
    public let frequentWords: [WordFrequency]

    public static let empty = WordCount(
        words: 0, characters: 0, sentences: 0, paragraphs: 0, readingSeconds: 0, frequentWords: []
    )
}

public enum WordCounter {
    public static func analyze(_ text: String, options: WordCounterOptions = .init()) async throws -> WordCount {
        try Task.checkCancellation()
        guard !text.isEmpty else { return .empty }

        var frequencies: [String: Int] = [:]
        var words = 0
        let frequencyLocale = Locale(identifier: "en_US_POSIX")
        try enumerate(.word, in: text) { token in
            if token.contains(where: isWordCharacter) {
                words += 1
                let normalized = token.precomposedStringWithCanonicalMapping
                    .folding(options: .caseInsensitive, locale: frequencyLocale)
                frequencies[normalized, default: 0] += 1
            }
        }

        var sentences = 0
        try enumerate(.sentence, in: text) { token in
            if token.contains(where: isWordCharacter) { sentences += 1 }
        }

        var paragraphs = 0
        try enumerate(.paragraph, in: text) { token in
            if token.contains(where: { !$0.isWhitespace }) { paragraphs += 1 }
        }

        var characters = 0
        for (offset, character) in text.enumerated() {
            if offset.isMultiple(of: 4_096) { try Task.checkCancellation() }
            if !options.excludesWhitespace || !character.isWhitespace { characters += 1 }
        }

        let ranked = frequencies.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        try Task.checkCancellation()
        let rate = max(1, options.wordsPerMinute)
        let seconds = Int((Double(words) / Double(rate) * 60).rounded(.up))
        return WordCount(
            words: words, characters: characters, sentences: sentences, paragraphs: paragraphs,
            readingSeconds: seconds, frequentWords: ranked.prefix(10).map {
                WordFrequency(word: $0.key, count: $0.value)
            }
        )
    }

    public static func loadText(_ file: URL) async throws -> String {
        guard file.isFileURL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("Choose a local plain-text file.")
        }
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        try Task.checkCancellation()
        guard let text = PlainTextDecoding.decode(data) else {
            throw ToolError.invalid("Could not read this file as UTF-8 or BOM-marked Unicode plain text.")
        }
        return text
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func enumerate(
        _ unit: NLTokenUnit, in text: String, visit: (Substring) -> Void
    ) throws {
        let tokenizer = NLTokenizer(unit: unit)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if Task.isCancelled { return false }
            visit(text[range])
            return true
        }
        try Task.checkCancellation()
    }
}
