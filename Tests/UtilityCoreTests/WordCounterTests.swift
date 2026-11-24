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

@Test func wordCounterLoadsDistinctSameNamedUnicodeFilesAndRejectsBinary() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("source.txt")
    let expected = "Bonjour, 世界"
    try #require(expected.data(using: .utf16)).write(to: file)
    let other = directory.appending(path: "Other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let second = other.appending(path: file.lastPathComponent)
    try Data("Hello from another file".utf8).write(to: second)
    let linked = directory.appending(path: "linked.txt")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: second)

    #expect(try await WordCounter.loadText(file) == expected)
    #expect(try await WordCounter.loadText(linked) == "Hello from another file")
    try Data([0x00, 0x01, 0xFF]).write(to: second)
    await #expect(throws: ToolError.self) { try await WordCounter.loadText(linked) }
    #expect(try await WordCounter.loadText(file) == expected)
}

@Test func wordCounterRejectsOversizedInputBeforeAnalysisOrFileDecoding() async throws {
    let maximumBytes = 2 * 1024 * 1024
    let text = String(repeating: "a", count: maximumBytes + 1)
    await #expect(throws: ToolError.self) { try await WordCounter.analyze(text) }

    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(maximumBytes + 1))
    try handle.close()
    let error = await #expect(throws: ToolError.self) { try await WordCounter.loadText(file) }
    #expect(error?.errorDescription == "Choose a plain-text file up to 2 MiB.")
}
