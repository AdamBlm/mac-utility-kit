import Foundation
import Testing
import UtilityCore

struct DiffCheckerTests {
    @Test func comparesBOMMarkedFilesAndRejectsMalformedOrOversizedInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let utf8 = folder.appending(path: "utf8.txt")
        let utf16 = folder.appending(path: "utf16.txt")
        let utf32 = folder.appending(path: "utf32.txt")
        let unreadable = folder.appending(path: "unreadable.txt")
        let text = "café 👋"
        try (Data([0xEF, 0xBB, 0xBF]) + Data("\(text)\nlast".utf8)).write(to: utf8)
        try (Data([0xFF, 0xFE]) + #require("\(text)\r\nlast".data(using: .utf16LittleEndian))).write(to: utf16)
        try (Data([0x00, 0x00, 0xFE, 0xFF]) + #require("\(text)\nchanged".data(using: .utf32BigEndian))).write(to: utf32)
        let original = try await DiffChecker.loadText(utf8)
        let same = try await DiffChecker.loadText(utf16)
        let modified = try await DiffChecker.loadText(utf32)
        #expect(original == "\(text)\nlast")
        #expect(try DiffChecker.compare(original, same).changeStarts.isEmpty)
        #expect(try DiffChecker.compare(original, modified).changeStarts == [1])

        try Data([0xFF, 0xFE, 0x61]).write(to: unreadable)
        await #expect(throws: DiffChecker.InputError.unsupportedEncoding) {
            try await DiffChecker.loadText(unreadable)
        }
        try Data([0x61, 0x00, 0x62]).write(to: unreadable)
        await #expect(throws: DiffChecker.InputError.unsupportedEncoding) {
            try await DiffChecker.loadText(unreadable)
        }
        try Data(repeating: 0x61, count: DiffChecker.maximumTextBytes + 1).write(to: unreadable)
        await #expect(throws: DiffChecker.InputError.tooManyBytes) {
            try await DiffChecker.loadText(unreadable)
        }
    }

    @Test func lineEndingsCanDifferAndEmptyInputsWork() throws {
        #expect(try DiffChecker.compare("", "").rows.isEmpty)
        #expect(try DiffChecker.compare("first\r\nsecond\r\n", "first\nsecond\n").changeStarts.isEmpty)
        #expect(try DiffChecker.compare("first\rsecond", "first\nsecond").changeStarts.isEmpty)
        let add = try DiffChecker.compare("", "first")
        #expect(add.changeStarts == [0])
        #expect(add.rows.first?.original == nil)
        #expect(add.rows.first?.modified?.text == "first")
        #expect(try DiffChecker.compare("first", "first\n").changeStarts == [1])
    }

    @Test func alignsChangesAndHighlightsOnlyChangedWords() throws {
        let result = try DiffChecker.compare(
            "header\nhello blue world\nunchanged\nremove me\nfooter",
            "header\nhello red world\nunchanged\nfooter"
        )
        #expect(result.changeStarts == [1, 3])
        #expect(result.rows[1].original?.segments.filter(\.changed).map(\.text) == ["blue"])
        #expect(result.rows[1].modified?.segments.filter(\.changed).map(\.text) == ["red"])
        #expect(result.rows[3].modified == nil)
        #expect(result.rows[4].modified?.number == 4)
        #expect(result.rows[4].original?.number == 5)
    }

    @Test func ignoresCaseAndWhitespaceWithoutDiscardingOriginalText() throws {
        let options = DiffChecker.Options(ignoreWhitespace: true, ignoreCase: true)
        let result = try DiffChecker.compare(" ECHo\t\nkeep old", "echo\nkeep  NEW", options: options)
        #expect(result.changeStarts == [1])
        #expect(result.rows[0].original?.text == " ECHo\t")
        #expect(result.rows[0].modified?.text == "echo")
        #expect(result.rows[1].modified?.segments.filter(\.changed).map(\.text) == ["NEW"])
        #expect(try DiffChecker.compare("é", "e\u{301}").changeStarts == [0])
    }

    @Test func ignoresBlankLinesAndRetainsOriginalLineNumbersAndChangeNavigation() throws {
        let options = DiffChecker.Options(ignoreBlankLines: true)
        let original = "header\r\n \r\nold blue\r\n\r\nkeep\r\nold green\r\n"
        let modified = "\nheader\nnew blue\nkeep\n\t\nnew green\n \n"
        let result = try DiffChecker.compare(original, modified, options: options)
        #expect(result.changeStarts == [1, 3])
        #expect(result.rows.map { $0.original?.number } == [1, 3, 5, 6, 7])
        #expect(result.rows.map { $0.modified?.number } == [2, 3, 4, 6, 7])
        #expect(result.rows[1].original?.segments.filter(\.changed).map(\.text) == ["old"])
        #expect(result.rows[3].modified?.segments.filter(\.changed).map(\.text) == ["new"])
        #expect(try DiffChecker.compare("x\n\n", "\nx\n\t", options: options).changeStarts.isEmpty)
        #expect(try DiffChecker.compare("x", "x\n\t", options: options).changeStarts == [1])
        #expect(try DiffChecker.compare("", " \n\t", options: options).changeStarts.isEmpty)
        #expect(try DiffChecker.compare("x\ny", "x\n\ny").changeStarts == [1])
    }

    @Test func capsExpensiveAlignmentAndRetainsMatchingEdges() throws {
        let original = "anchor\n" + Array(repeating: "before", count: 1_005).joined(separator: "\n") + "\nend"
        let modified = "anchor\n" + Array(repeating: "after", count: 1_005).joined(separator: "\n") + "\nend"
        let result = try DiffChecker.compare(original, modified)
        #expect(result.usedCoarseAlignment)
        #expect(result.changeStarts == [1])
        #expect(result.rows.count == 1_007)
        #expect(result.rows.first?.changed == false)
        #expect(result.rows.last?.changed == false)
    }

    @Test func retainsDistantChangesAcrossLongSharedInterior() throws {
        let middle = (1...1_998).map { "unchanged line \($0)" }
        let original = (["original head"] + middle + ["original tail"]).joined(separator: "\n")
        let modified = (["modified head"] + middle + ["modified tail"]).joined(separator: "\n")
        let result = try DiffChecker.compare(original, modified)
        #expect(!result.usedCoarseAlignment)
        #expect(result.changeStarts == [0, 1_999])
        #expect(result.rows.filter(\.changed).count == 2)
        #expect(result.rows[1_200].original?.number == 1_201)
        #expect(result.rows[1_200].modified?.number == 1_201)
    }

    @Test func anchorsRepeatedLinesAndHandlesUnequalGaps() throws {
        let repeated = Array(repeating: "same line", count: 2_000)
        let original = (["original head"] + repeated + ["original tail"]).joined(separator: "\n")
        let modified = (["modified head", "added line"] + repeated + ["modified tail"]).joined(separator: "\n")
        let result = try DiffChecker.compare(original, modified)
        #expect(!result.usedCoarseAlignment)
        #expect(result.changeStarts == [0, 2_002])
        #expect(result.rows.filter(\.changed).count == 3)
        #expect(result.rows[2].original?.number == 2)
        #expect(result.rows[2].modified?.number == 3)
    }

    @Test func anchorsRepeatingInteriorWhenAnOccurrenceIsAdded() throws {
        let repeated = Array(repeating: "same line", count: 2_000)
        let original = (["original head"] + repeated + ["original tail"]).joined(separator: "\n")
        let modified = (["modified head"] + repeated + ["same line", "modified tail"]).joined(separator: "\n")
        let result = try DiffChecker.compare(original, modified)
        #expect(!result.usedCoarseAlignment)
        #expect(result.changeStarts == [0, 2_001])
        #expect(result.rows.filter(\.changed).count == 3)
    }

    @Test func movedUniqueLineDoesNotHideLongerRepeatedMatch() throws {
        let repeated = Array(repeating: "same line", count: 1_500)
        let original = (["old head"] + repeated + ["marker", "old tail"]).joined(separator: "\n")
        let modified = (["new head", "marker"] + repeated + ["new tail"]).joined(separator: "\n")
        let result = try DiffChecker.compare(original, modified)
        #expect(!result.usedCoarseAlignment)
        #expect(result.changeStarts == [0, 1_502])
        #expect(result.rows.filter { !$0.changed }.count == 1_500)
    }

    @Test func alignsSingletonAgainstMaximumLengthInputBothWays() throws {
        var lines = Array(repeating: "other", count: DiffChecker.maximumLines)
        lines[12_500] = "match"
        let full = lines.joined(separator: "\n")
        for (original, modified) in [("match", full), (full, "match")] {
            let result = try DiffChecker.compare(original, modified)
            #expect(!result.usedCoarseAlignment)
            #expect(result.changeStarts == [0, 12_501])
            #expect(result.rows[12_500].original?.text == "match")
            #expect(result.rows[12_500].modified?.text == "match")
            #expect(result.rows.count == DiffChecker.maximumLines)
        }
    }
}
