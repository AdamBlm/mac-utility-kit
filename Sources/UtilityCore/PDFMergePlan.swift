import Darwin
import Foundation

public struct PDFMergePageReference: Hashable, Sendable {
    public let source: Int
    public let page: Int

    /// Source and page indices are zero-based. Page ranges entered by users remain one-based.
    public init(source: Int, page: Int) {
        self.source = source
        self.page = page
    }
}

public struct PDFMergeSourceStamp: Equatable, Sendable {
    private let resolved: URL
    private let stamp: DuplicateFileStamp

    public static func read(_ input: URL) throws -> Self {
        let resolved = input.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard input.isFileURL, stat(resolved.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent).")
        }
        return Self(resolved: resolved, stamp: DuplicateFileStamp(metadata))
    }

    func validate(_ input: URL) throws {
        guard (try? Self.read(input)) == self else {
            throw ToolError.invalid("\(input.lastPathComponent) changed after preview. Refresh the source previews before merging.")
        }
    }
}

public enum PDFMergePlan {
    public static func selectedPages(counts: [Int], ranges: [String]) throws -> [PDFMergePageReference] {
        try counts.enumerated().flatMap { source, count in
            guard count >= 0 else { throw ToolError.invalid("The source page count is invalid.") }
            let expression = ranges.indices.contains(source) ? ranges[source] : ""
            return try PageSelection.indices(expression, pageCount: count).map {
                PDFMergePageReference(source: source, page: $0)
            }
        }
    }

    public static func reconcile(
        selected: [PDFMergePageReference], custom: [PDFMergePageReference]?
    ) -> [PDFMergePageReference] {
        guard let custom else { return selected }
        var remaining = Set(selected)
        let current = custom.filter { remaining.remove($0) != nil }
        return current + selected.filter { remaining.contains($0) }
    }

    static func validate(
        _ custom: [PDFMergePageReference]?, against selected: [PDFMergePageReference]
    ) throws -> [PDFMergePageReference] {
        let pages = custom ?? selected
        guard !pages.isEmpty else { throw ToolError.invalid("Select at least one page to merge.") }
        guard pages.count == selected.count, Set(pages) == Set(selected) else {
            throw ToolError.invalid("The merge page order no longer matches the selected pages.")
        }
        return pages
    }
}
