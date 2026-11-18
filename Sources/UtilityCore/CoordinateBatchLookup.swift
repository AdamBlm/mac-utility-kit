import Foundation

public enum CoordinateBatchLookup {
    public struct Entry: Sendable {
        public let line: Int
        public let input: String
        let lookup: Lookup
    }

    enum Lookup: Sendable {
        case coordinate(MapCoordinate)
        case place(String)
        case rejected(Rejection)
    }

    public enum Rejection: String, Equatable, Sendable {
        case tooLong = "Enter up to 512 bytes for this row."
        case invalidCoordinate = "Invalid latitude or longitude."
        case noMatch = "No matching place."
        case searchUnavailable = "Map search unavailable."
    }

    public enum Outcome: Equatable, Sendable {
        case accepted(MapCoordinate)
        case rejected(Rejection)
    }

    public struct Row: Identifiable, Sendable {
        public var id: Int { line }
        public let line: Int
        public let input: String
        public let outcome: Outcome
    }

    public static func prepare(_ text: String) throws -> [Entry] {
        var entries: [Entry] = []
        var position = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            start = end < text.endIndex ? text.index(after: end) : end
            position += 1
            guard !line.isEmpty else { continue }
            guard entries.count < 20 else {
                throw ToolError.invalid("Look up up to 20 nonempty lines at a time.")
            }
            if line.utf8.count > 512 {
                entries.append(Entry(line: position, input: String(decoding: line.utf8.prefix(80), as: UTF8.self) + "…", lookup: .rejected(.tooLong)))
            } else {
                let lookup: Lookup
                if let coordinate = try? MapCoordinate.parse(line) {
                    lookup = .coordinate(coordinate)
                } else if looksLikeCoordinates(line) {
                    lookup = .rejected(.invalidCoordinate)
                } else {
                    lookup = .place(line)
                }
                entries.append(Entry(line: position, input: line, lookup: lookup))
            }
        }
        guard !entries.isEmpty else { throw ToolError.invalid("Enter at least one coordinate or place name.") }
        return entries
    }

    public static func resolve(
        _ entry: Entry, isolation: isolated (any Actor)? = #isolation,
        search: (String) async throws -> MapCoordinate?
    ) async throws -> Row {
        try Task.checkCancellation()
        let outcome: Outcome
        switch entry.lookup {
        case .coordinate(let coordinate):
            outcome = .accepted(coordinate)
        case .rejected(let rejection):
            outcome = .rejected(rejection)
        case .place(let name):
            do {
                let result = try await search(name)
                try Task.checkCancellation()
                outcome = result.map(Outcome.accepted) ?? .rejected(.noMatch)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                outcome = .rejected(.searchUnavailable)
            }
        }
        return Row(line: entry.line, input: entry.input, outcome: outcome)
    }

    private static func looksLikeCoordinates(_ line: String) -> Bool {
        if line.contains("°") { return true }
        if line.wholeMatch(of: /[+−\-]?[0-9.]+\s*[,; ]\s*[+−\-]?[0-9.]+/) != nil { return true }
        if line.wholeMatch(of: /[+−\-]?[0-9.]+\s*[,;]\s*/) != nil { return true }
        if line.prefixMatch(of: /[+−\-]?[0-9.]+\s*;/) != nil { return true }
        if line.prefixMatch(of: /(?:[+−\-][0-9.]+|[0-9]*\.[0-9]+)\s*,/) != nil { return true }
        // Treat a bare integer and lone word as an incomplete coordinate,
        // while keeping multiword or comma-delimited address queries.
        return line.wholeMatch(of: /[0-9]{1,3}\s*,\s*\p{L}+/) != nil
    }
}
