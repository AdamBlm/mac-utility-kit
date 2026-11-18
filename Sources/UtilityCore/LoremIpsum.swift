import Foundation

public enum LoremIpsum {
    public enum Unit: String, CaseIterable, Identifiable, Sendable {
        case words = "Words"
        case sentences = "Sentences"
        case paragraphs = "Paragraphs"

        public var id: Self { self }

        public var limit: Int {
            switch self {
            case .words: 10_000
            case .sentences: 1_000
            case .paragraphs: 200
            }
        }
    }

    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case plain = "Plain Text"
        case html = "HTML"
        case markdown = "Markdown"

        public var id: Self { self }
        public var fileExtension: String {
            switch self {
            case .plain: "txt"
            case .html: "html"
            case .markdown: "md"
            }
        }
    }

    private static let opening = "Lorem ipsum dolor sit amet"
    private static let vocabulary = """
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore
    magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo
    consequat duis aute irure reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint
    occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum proin gravida nibh
    vel auctor aliquet sollicitudin ultrices sapien varius tempus dignissim integer posuere metus vitae lectus
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    public static func generate(count: Int, unit: Unit, format: Format, startsWithLorem: Bool = true) throws -> String {
        guard (1...unit.limit).contains(count) else {
            throw ToolError.invalid("Choose 1 to \(unit.limit) \(unit.rawValue.lowercased()).")
        }
        var random = SystemRandomNumberGenerator()
        var startsWithLorem = startsWithLorem
        switch unit {
        case .words:
            let text = words(count: count, startsWithLorem: &startsWithLorem, random: &random).joined(separator: " ")
            return format == .html ? htmlParagraph(text) : text
        case .sentences:
            let text = (0..<count).map { _ in sentence(startsWithLorem: &startsWithLorem, random: &random) }.joined(separator: " ")
            return format == .html ? htmlParagraph(text) : text
        case .paragraphs:
            let paragraphs = (0..<count).map { _ in
                let length = Int.random(in: 3...6, using: &random)
                return (0..<length).map { _ in sentence(startsWithLorem: &startsWithLorem, random: &random) }.joined(separator: " ")
            }
            return format == .html ? paragraphs.map(htmlParagraph).joined(separator: "\n") : paragraphs.joined(separator: "\n\n")
        }
    }

    private static func sentence(startsWithLorem: inout Bool, random: inout SystemRandomNumberGenerator) -> String {
        let count = Int.random(in: 8...17, using: &random)
        let line = words(count: count, startsWithLorem: &startsWithLorem, random: &random).joined(separator: " ")
        return line.prefix(1).uppercased() + line.dropFirst() + "."
    }

    private static func words(count: Int, startsWithLorem: inout Bool, random: inout SystemRandomNumberGenerator) -> [String] {
        var output = startsWithLorem ? opening.split(separator: " ").prefix(count).map(String.init) : []
        startsWithLorem = false
        var lastIndex = output.last.flatMap { vocabulary.firstIndex(of: $0) }
        for _ in output.count..<count {
            let available = vocabulary.count - (lastIndex == nil ? 0 : 1)
            var index = Int.random(in: 0..<available, using: &random)
            if let lastIndex, index >= lastIndex { index += 1 }
            output.append(vocabulary[index])
            lastIndex = index
        }
        return output
    }

    private static func htmlParagraph(_ text: String) -> String {
        // The corpus contains only Latin letters, spaces, and sentence punctuation.
        "<p>\(text)</p>"
    }
}
