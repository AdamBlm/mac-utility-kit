import Testing
import UtilityCore

struct LoremIpsumTests {
    @Test func generatesExactWordSentenceAndParagraphCounts() throws {
        let words = try LoremIpsum.generate(count: 9, unit: .words, format: .plain)
        #expect(words.hasPrefix("Lorem ipsum dolor sit amet "))
        #expect(words.split(separator: " ").count == 9)
        let sentences = try LoremIpsum.generate(count: 4, unit: .sentences, format: .markdown)
        #expect(sentences.split(separator: ".").count == 4)
        let paragraphs = try LoremIpsum.generate(count: 3, unit: .paragraphs, format: .html)
        #expect(paragraphs.split(separator: "\n").count == 3)
        #expect(paragraphs.split(separator: "\n").allSatisfy { $0.hasPrefix("<p>") && $0.hasSuffix("</p>") })
    }

    @Test func rejectsCountsBeyondTheSelectedUnitLimit() {
        #expect(throws: ToolError.self) {
            try LoremIpsum.generate(count: 0, unit: .words, format: .plain)
        }
        #expect(throws: ToolError.self) {
            try LoremIpsum.generate(count: LoremIpsum.Unit.paragraphs.limit + 1, unit: .paragraphs, format: .plain)
        }
    }
}
