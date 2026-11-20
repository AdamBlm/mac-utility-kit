import Foundation
import Testing
@testable import UtilityCore

struct BatchFindReplaceTests {
    @Test func previewsLiteralReplacementsAndExportsOnlyReviewedChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let edited = directory.appendingPathComponent("notes.txt")
        let untouched = directory.appendingPathComponent("other.txt")
        let unreadable = directory.appendingPathComponent("broken.txt")
        try Data("Use a.b and A.B.".utf8).write(to: edited)
        try Data("Use axb.".utf8).write(to: untouched)
        try Data([0, 255, 0]).write(to: unreadable)
        var options = BatchFindReplaceOptions()
        options.pattern = "a.b"
        options.replacement = "$1\\literal"
        options.ignoresCase = true
        let review = try await BatchFindReplace.preview([edited, untouched, unreadable], options: options)
        #expect(review.map(\.count) == [2, 0, 0])
        #expect(review.last?.error != nil)
        #expect(review[0].after == "Use $1\\literal and $1\\literal.")
        let result = try await BatchFindReplace.export(review, to: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.path) == ["1 - notes.txt"])
        #expect(try String(contentsOf: result.appendingPathComponent("1 - notes.txt"), encoding: .utf8) == review[0].after)
        #expect(try String(contentsOf: edited, encoding: .utf8) == "Use a.b and A.B.")
    }

    @Test func checksSourceAgainBeforePublishingAndSupportsManyLiteralMatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("notes.txt")
        try Data(String(repeating: "a", count: 3_000).utf8).write(to: source)
        var options = BatchFindReplaceOptions()
        options.pattern = "a"
        options.replacement = "b"
        let review = try await BatchFindReplace.preview([source], options: options)
        #expect(review.first?.count == 3_000)
        try Data("changed".utf8).write(to: source, options: .atomic)
        await #expect(throws: ToolError.self) {
            _ = try await BatchFindReplace.export(review, to: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notes.txt"])
    }

    @Test func replacesRegexCaptureGroups() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("12 cats".utf8).write(to: source)
        var options = BatchFindReplaceOptions()
        options.regularExpression = true
        options.pattern = #"([0-9]+) ([a-z]+)"#
        options.replacement = "$2: $1"
        let review = try await BatchFindReplace.preview([source], options: options)
        #expect(review.first?.after == "cats: 12")
    }
}
