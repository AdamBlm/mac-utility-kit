import Testing
import UtilityCore

struct CoordinateBatchLookupTests {
    @Test func malformedOversizedAndOfflineRowsPreserveValidLocalAndPlaceResultsInOrder() async throws {
        let text = ["48.85, 2.35", "", String(repeating: "é", count: 260), "95, 12",
                    "48.85, broken", "Offline", "Unmatched", "Place", "−33.85, 151.21"]
            .joined(separator: "\r\n")
        let input = try CoordinateBatchLookup.prepare(text)
        let searchedPoint = try MapCoordinate(latitude: 34, longitude: -118)
        var searches: [String] = []
        var rows: [CoordinateBatchLookup.Row] = []
        for entry in input {
            let row = try await CoordinateBatchLookup.resolve(entry) { term in
                searches.append(term)
                switch term {
                case "Offline": throw ToolError.invalid("Network unavailable")
                case "Place": return searchedPoint
                default: return nil
                }
            }
            rows.append(row)
        }
        #expect(searches == ["Offline", "Unmatched", "Place"])
        #expect(rows.map(\.line) == [1, 3, 4, 5, 6, 7, 8, 9])
        let first = try MapCoordinate.parse("48.85, 2.35")
        let last = try MapCoordinate.parse("−33.85, 151.21")
        #expect(rows.map(\.outcome) == [
            .accepted(first), .rejected(.tooLong), .rejected(.invalidCoordinate),
            .rejected(.invalidCoordinate), .rejected(.searchUnavailable), .rejected(.noMatch),
            .accepted(searchedPoint), .accepted(last)
        ])
    }

    @Test func rejectsAnIntegerCoordinateWithAMalformedSecondPartButStillSearchesAddresses() async throws {
        let entries = try CoordinateBatchLookup.prepare("48, broken\n10, Downing Street\n48, Paris, France")
        let invalid = try await CoordinateBatchLookup.resolve(entries[0]) { _ in
            Issue.record("The malformed coordinate should be rejected locally.")
            return nil
        }
        #expect(invalid.outcome == .rejected(.invalidCoordinate))
        var searched: [String] = []
        for entry in entries.dropFirst() {
            let result = try await CoordinateBatchLookup.resolve(entry) { name in
                searched.append(name)
                return nil
            }
            #expect(result.outcome == .rejected(.noMatch))
        }
        #expect(searched == ["10, Downing Street", "48, Paris, France"])
    }

    @Test func boundsNonemptyLineCountAndPropagatesCancellation() async throws {
        #expect(throws: ToolError.self) { try CoordinateBatchLookup.prepare("\n \r\n") }
        #expect(throws: ToolError.self) {
            try CoordinateBatchLookup.prepare(Array(repeating: "Place", count: 21).joined(separator: "\n"))
        }
        let entry = try #require(CoordinateBatchLookup.prepare("Place").first)
        await #expect(throws: CancellationError.self) {
            _ = try await CoordinateBatchLookup.resolve(entry) { _ in throw CancellationError() }
        }
    }
}
