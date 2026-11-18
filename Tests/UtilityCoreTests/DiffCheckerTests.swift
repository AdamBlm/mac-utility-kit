import Testing
import UtilityCore

struct DiffCheckerTests {
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
}
