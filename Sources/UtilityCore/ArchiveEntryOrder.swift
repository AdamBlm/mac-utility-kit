import Foundation

package enum ArchiveEntryOrder: String, CaseIterable, Identifiable, Sendable {
    case archive = "Archive Order"
    case path = "Path"
    case largestFirst = "Largest First"

    package var id: Self { self }

    package func rows(_ entries: [ArchiveEntry], matching query: String) throws -> [ArchiveEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = if term.isEmpty {
            entries
        } else {
            try entries.filter {
                try Task.checkCancellation()
                return $0.path.localizedStandardContains(term)
            }
        }
        guard self != .archive else { return visible }
        return try visible.sorted { first, second in
            try Task.checkCancellation()
            if self == .largestFirst {
                let firstSize = first.isDirectory ? -1 : first.uncompressedSize ?? -1
                let secondSize = second.isDirectory ? -1 : second.uncompressedSize ?? -1
                if firstSize != secondSize { return firstSize > secondSize }
            }
            let comparison = first.path.localizedStandardCompare(second.path)
            return comparison == .orderedSame ? first.id.ordinal < second.id.ordinal : comparison == .orderedAscending
        }
    }

    package static func extractionSelection(for matches: Set<ArchiveEntry.ID>, in entries: [ArchiveEntry]) -> Set<ArchiveEntry.ID> {
        // Selecting an explicit directory would also extract all of its descendants.
        var ancestorsOfHiddenEntries: Set<String> = []
        for entry in entries where !matches.contains(entry.id) {
            var path = entry.path[...]
            while let separator = path.lastIndex(of: "/") {
                path = path[..<separator]
                ancestorsOfHiddenEntries.insert(String(path))
            }
        }
        return matches.filter { !$0.directory || !ancestorsOfHiddenEntries.contains($0.path) }
    }
}
