import Testing
import UtilityCore

struct RegexTesterTests {
    @Test func capturesNamedAndNumberedGroupsAndReplaces() throws {
        let result = try RegexTester.evaluate(
            pattern: #"(?<name>\w+)=(\d+)"#, sample: "é=7, two=12", replacement: "${name}:$2"
        )
        #expect(result.matches.count == 2)
        #expect(result.matches.first?.captures[1].name == "name")
        #expect(result.matches.first?.captures[2].text == "7")
        #expect(result.replacement == "é:7, two:12")
    }

    @Test func handlesZeroWidthMatchesAndOptions() throws {
        var options = RegexTesterOptions()
        options.multiline = true
        options.ignoresCase = true
        let result = try RegexTester.evaluate(pattern: "^(?=a)", sample: "A\na", replacement: ">", options: options)
        #expect(result.matches.count == 2)
        #expect(result.matches.allSatisfy { $0.captures.first?.range?.isEmpty == true })
        #expect(result.replacement == ">A\n>a")
    }

    @Test func surfacesInvalidPatternsAndStopsCatastrophicBacktracking() {
        #expect(throws: ToolError.self) { try RegexTester.evaluate(pattern: "(", sample: "") }
        #expect(throws: ToolError.self) {
            try RegexTester.evaluate(pattern: "^(a+)+$", sample: String(repeating: "a", count: 64) + "!")
        }
    }
}
