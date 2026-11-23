import AppKit
import Foundation
import Testing
@testable import UtilityCore

struct BatchFindReplaceTests {
    @MainActor
    @Test func previewsLiteralReplacementsAndExportsOnlyReviewedChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let edited = directory.appendingPathComponent("notes.txt")
        let secondFolder = directory.appending(path: "Other Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: false)
        let second = secondFolder.appending(path: edited.lastPathComponent)
        let untouched = directory.appendingPathComponent("other.txt")
        let unreadable = directory.appendingPathComponent("broken.txt")
        try Data("Use a.b and A.B.".utf8).write(to: edited)
        try Data("axb and a.b".utf8).write(to: second)
        try Data("Use axb.".utf8).write(to: untouched)
        try Data([0, 255, 0]).write(to: unreadable)
        var options = BatchFindReplaceOptions()
        options.pattern = "a.b"
        options.replacement = "$1\\literal"
        options.ignoresCase = true
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let queued = [edited, untouched, unreadable, second]
        try #require(board.writeObjects(queued.map { $0 as NSURL }))
        let imported = ClipboardFiles.read(from: board, allowedTypes: Tool.batchFindReplace.inputTypes)
        #expect(imported == queued)
        let review = try await BatchFindReplace.preview(imported, options: options)
        #expect(review.map(\.count) == [2, 0, 0, 1])
        #expect(review[2].error != nil)
        #expect(review[0].after == "Use $1\\literal and $1\\literal.")
        let result = try await BatchFindReplace.export(review, to: directory)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: result.path)) == ["1 - notes.txt", "4 - notes.txt"])
        #expect(try String(contentsOf: result.appendingPathComponent("1 - notes.txt"), encoding: .utf8) == review[0].after)
        #expect(try String(contentsOf: edited, encoding: .utf8) == "Use a.b and A.B.")
        #expect(try String(contentsOf: result.appendingPathComponent("4 - notes.txt"), encoding: .utf8) == review[3].after)
        #expect(try String(contentsOf: second, encoding: .utf8) == "axb and a.b")
    }

    @Test func batchRejectsNonlocalAuthoritiesAndKeepsValidInputs() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.txt")
        let second = folder.appending(path: "second.txt")
        try Data("before first".utf8).write(to: first)
        try Data("before second".utf8).write(to: second)
        var remoteComponents = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false))
        remoteComponents.host = "other-machine.invalid"
        let remote = try #require(remoteComponents.url)
        var localComponents = try #require(URLComponents(url: second, resolvingAgainstBaseURL: false))
        localComponents.host = "localhost"
        let localhost = try #require(localComponents.url)
        var options = BatchFindReplaceOptions()
        options.pattern = "before"
        options.replacement = "after"

        let preview = try await BatchFindReplace.preview([first, remote, localhost], options: options)
        #expect(preview.map(\.error) == [nil, "Choose a local file.", nil])
        #expect(preview.map(\.count) == [1, 0, 1])
        let output = try await BatchFindReplace.export(preview, to: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() ==
                ["1 - first.txt", "3 - second.txt"])
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

    @Test func exportsMixedUnicodeEncodingsWithTheirOriginalByteOrderMarks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let formats: [(String.Encoding, [UInt8])] = [
            (.utf8, []), (.utf8, [0xEF, 0xBB, 0xBF]),
            (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF]),
            (.utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00]), (.utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF])
        ]
        var inputs: [URL] = []
        var originals: [Data] = []
        var expected: [Data] = []
        let names = ["README", "notes.md", "notes.rst", ".gitignore", "notes.TXT",
                     String(repeating: "x", count: 252) + ".md"]
        for (name, (encoding, marker)) in zip(names, formats) {
            let input = directory.appendingPathComponent(name)
            let body = try #require("before 🐈\r\n".data(using: encoding))
            let newBody = try #require("après 🐈\r\n".data(using: encoding))
            let original = Data(marker) + body
            try original.write(to: input)
            inputs.append(input)
            originals.append(original)
            expected.append(Data(marker) + newBody)
        }
        var options = BatchFindReplaceOptions()
        options.pattern = "before"
        options.replacement = "après"
        let review = try await BatchFindReplace.preview(inputs, options: options)
        #expect(review.allSatisfy { $0.count == 1 && $0.changed && $0.error == nil })
        let result = try await BatchFindReplace.export(review, to: directory)
        let outputNames = ["1 - README", "2 - notes.md", "3 - notes.rst", "4 - .gitignore", "5 - notes.TXT",
                           "6 - " + String(repeating: "x", count: 248) + ".md"]
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: result.path)) == Set(outputNames))
        for (index, input) in inputs.enumerated() {
            let output = result.appendingPathComponent(outputNames[index])
            #expect(try Data(contentsOf: output) == expected[index])
            #expect(try Data(contentsOf: input) == originals[index])
        }
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
