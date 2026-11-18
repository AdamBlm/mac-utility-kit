import Foundation
import Testing
import UtilityCore

@Test func wordCounterCountsAllUnitsAndRanksCaseFoldedWords() async throws {
    var options = WordCounterOptions()
    options.wordsPerMinute = 120
    let result = try await WordCounter.analyze("Swift swift is fun.\n\nSwift is useful!", options: options)
    #expect(result.words == 7)
    #expect(result.sentences == 2)
    #expect(result.paragraphs == 2)
    #expect(result.readingSeconds == 4)
    #expect(result.frequentWords.first?.word == "swift")
    #expect(result.frequentWords.first?.count == 3)
}

@Test func wordCounterCountsGraphemesAndCanExcludeUnicodeWhitespace() async throws {
    var options = WordCounterOptions()
    options.excludesWhitespace = true
    let text = "e\u{301}\t👩‍💻\u{00A0}猫\r\n!"
    let matching = try await WordCounter.analyze(text, options: options)
    let all = try await WordCounter.analyze(text)
    #expect(matching.characters == 4)
    #expect(all.characters == 7)
    #expect(matching.words == 2)
}

@Test func wordCounterHandlesEmptyWhitespaceAndPunctuation() async throws {
    let empty = try await WordCounter.analyze("")
    let whitespace = try await WordCounter.analyze("  \n\t \n")
    let punctuation = try await WordCounter.analyze("!!! … ?")
    #expect(empty == .empty)
    #expect(whitespace.words == 0 && whitespace.sentences == 0 && whitespace.paragraphs == 0)
    #expect(punctuation.words == 0 && punctuation.sentences == 0)
    #expect(punctuation.frequentWords.isEmpty && punctuation.readingSeconds == 0)
}

@Test func wordCounterLoadsUnicodeTextAndRejectsBinary() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("source.txt")
    let expected = "Bonjour, 世界"
    try #require(expected.data(using: .utf16)).write(to: file)
    #expect(try await WordCounter.loadText(file) == expected)
    try Data([0x00, 0x01, 0xFF]).write(to: file)
    await #expect(throws: ToolError.self) { try await WordCounter.loadText(file) }
}
