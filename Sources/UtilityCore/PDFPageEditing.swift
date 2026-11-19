import Foundation
import PDFKit

public enum PDFSplitMode: String, CaseIterable, Identifiable, Sendable {
    case eachPage = "Each page"
    case everyN = "Every N pages"
    case custom = "Custom ranges"

    public var id: Self { self }
}

public struct PDFSplitOptions: Sendable {
    public var mode: PDFSplitMode = .eachPage
    public var pagesPerFile = 2
    public var customRanges = ""
    public var filenamePattern = "{name}-{number}"
    public var password = ""

    public init() {}
}

public struct PDFSplitGroup: Identifiable, Sendable {
    public let number: Int
    public let name: String
    public let pageNumbers: [Int]

    public var id: Int { number }
}

public struct PDFPageEdit: Identifiable, Hashable, Sendable {
    public let pageNumber: Int
    public let quarterTurns: Int

    public var id: Int { pageNumber }

    public init(pageNumber: Int, quarterTurns: Int = 0) {
        self.pageNumber = pageNumber
        self.quarterTurns = quarterTurns
    }
}

public struct PDFOrganizeOptions: Sendable {
    public var pages: [PDFPageEdit]?
    public var password = ""

    public init() {}
}

public struct PDFDeleteOptions: Sendable {
    public var range = ""
    public var password = ""

    public init() {}
}

public enum PDFExtractOrder: String, CaseIterable, Identifiable, Sendable {
    case document = "Document order"
    case selection = "Selection order"

    public var id: Self { self }
}

public struct PDFExtractOptions: Sendable {
    public var range = ""
    public var order: PDFExtractOrder = .document
    public var password = ""

    public init() {}
}

public enum PDFPageEditing {
    public static func extractPages(pageCount: Int, options: PDFExtractOptions) throws -> [Int] {
        guard pageCount > 0 else { throw ToolError.invalid("The PDF has no pages.") }
        let range = options.range.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !range.isEmpty else { throw ToolError.invalid("Select at least one page to extract.") }
        let pages = try PageSelection.indices(range, pageCount: pageCount).map { $0 + 1 }
        guard !pages.isEmpty else { throw ToolError.invalid("Select at least one page to extract.") }
        return options.order == .document ? pages.sorted() : pages
    }

    public static func extract(
        _ input: URL, to output: URL, options: PDFExtractOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let original = try open(input, password: options.password)
        let selected = try extractPages(pageCount: original.pageCount, options: options)
        try writeCopy(selected.map { PDFPageEdit(pageNumber: $0) }, from: original, to: output)
        await progress(1)
    }

    public static func pageCount(_ input: URL, password: String = "") throws -> Int {
        try open(input, password: password).pageCount
    }

    public static func splitGroups(pageCount: Int, options: PDFSplitOptions) throws -> [PDFSplitGroup] {
        guard pageCount > 0 else { throw ToolError.invalid("The PDF has no pages.") }
        switch options.mode {
        case .eachPage, .everyN:
            let count = options.mode == .eachPage ? 1 : options.pagesPerFile
            guard count > 0 else { throw ToolError.invalid("Enter at least one page per file.") }
            let size = min(count, pageCount)
            return stride(from: 0, to: pageCount, by: size).enumerated().map { index, start in
                let first = start + 1
                let last = start + min(size, pageCount - start)
                return PDFSplitGroup(number: index + 1, name: first == last ? "Page \(first)" : "Pages \(first)–\(last)",
                                     pageNumbers: Array(first...last))
            }
        case .custom:
            let lines = options.customRanges.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .enumerated()
                .map { (number: $0.offset + 1, text: $0.element.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.text.isEmpty }
            guard !lines.isEmpty else { throw ToolError.invalid("Enter at least one custom page range.") }
            return try lines.enumerated().map { index, line in
                let parts = line.text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let range = parts.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                let name = parts.count == 2 ? parts[0].trimmingCharacters(in: .whitespaces) : "Group \(index + 1)"
                guard !range.isEmpty, !name.isEmpty else {
                    throw ToolError.invalid("Line \(line.number) needs a page range and a name when a colon is used.")
                }
                let pages: [Int]
                do {
                    pages = try PageSelection.indices(range, pageCount: pageCount).map { $0 + 1 }
                } catch {
                    throw ToolError.invalid("Line \(line.number): \(error.localizedDescription)")
                }
                guard !pages.isEmpty else {
                    throw ToolError.invalid("Line \(line.number) must contain at least one page.")
                }
                return PDFSplitGroup(number: index + 1, name: name, pageNumbers: pages)
            }
        }
    }

    public static func splitFilenames(
        _ input: URL, groups: [PDFSplitGroup], pattern: String
    ) throws -> [String] {
        let stem = input.deletingPathExtension().lastPathComponent
        var names: Set<String> = []
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { throw ToolError.invalid("Enter a filename pattern.") }
        return try groups.map { group in
            let number = String(group.number)
            let padded = String(repeating: "0", count: max(0, String(groups.count).count - number.count)) + number
            let replacements = ["{name}": stem, "{number}": padded, "{group}": group.name]
            var name = ""
            var remainder = pattern[...]
            while let first = remainder.first {
                switch first {
                case "{":
                    guard let end = remainder.firstIndex(of: "}"),
                          let replacement = replacements[String(remainder[...end])] else {
                        throw ToolError.invalid("Use {name}, {number}, or {group} in the filename pattern.")
                    }
                    name += replacement
                    remainder = remainder[remainder.index(after: end)...]
                case "}":
                    throw ToolError.invalid("Use {name}, {number}, or {group} in the filename pattern.")
                default:
                    name.append(first)
                    remainder.removeFirst()
                }
            }
            guard !name.isEmpty, name != ".", name != "..",
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  !name.contains("/"), !name.contains(":") else {
                throw ToolError.invalid("The filename pattern produced an invalid name.")
            }
            if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
            let normalized = name.precomposedStringWithCanonicalMapping
            guard OutputFilename.fits(name) else {
                throw ToolError.invalid("The output filename is too long. Shorten the pattern or group name.")
            }
            guard names.insert(normalized.lowercased()).inserted else {
                throw ToolError.invalid("The filename pattern repeats an output name. Add {number} to make each name unique.")
            }
            return name
        }
    }

    public static func split(
        _ input: URL, into directory: URL, options: PDFSplitOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws -> [URL] {
        try Task.checkCancellation()
        let original = try open(input, password: options.password)
        let groups = try splitGroups(pageCount: original.pageCount, options: options)
        let names = try splitFilenames(input, groups: groups, pattern: options.filenamePattern)
        let outputs = names.map { directory.appendingPathComponent($0) }
        let manager = FileManager.default
        guard outputs.allSatisfy({ !manager.fileExists(atPath: $0.path) }) else {
            throw ToolError.invalid("A split output filename already exists.")
        }
        let staging = try stagingFolder(in: directory)
        defer { try? manager.removeItem(at: staging) }
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            try writePages(group.pageNumbers.map { PDFPageEdit(pageNumber: $0) }, from: original,
                           to: staging.appendingPathComponent(names[index]))
            await progress(Double(index + 1) / Double(groups.count + 1))
        }
        var published: [URL] = []
        do {
            for output in outputs {
                try Task.checkCancellation()
                try manager.moveItem(at: staging.appendingPathComponent(output.lastPathComponent), to: output)
                published.append(output)
            }
        } catch {
            for output in published { try? manager.removeItem(at: output) }
            throw error
        }
        await progress(1)
        return outputs
    }

    public static func organize(
        _ input: URL, to output: URL, options: PDFOrganizeOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let original = try open(input, password: options.password)
        let pages = options.pages ?? (1...original.pageCount).map { PDFPageEdit(pageNumber: $0) }
        try writeCopy(pages, from: original, to: output)
        await progress(1)
    }

    public static func delete(
        _ input: URL, to output: URL, options: PDFDeleteOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let original = try open(input, password: options.password)
        let range = options.range.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !range.isEmpty else { throw ToolError.invalid("Select at least one page to remove.") }
        let removed = Set(try PageSelection.indices(range, pageCount: original.pageCount))
        guard !removed.isEmpty else { throw ToolError.invalid("Select at least one page to remove.") }
        let remaining = (0..<original.pageCount).filter { !removed.contains($0) }
        try writeCopy(remaining.map { PDFPageEdit(pageNumber: $0 + 1) }, from: original, to: output)
        await progress(1)
    }

    private static func open(_ input: URL, password: String) throws -> PDFDocument {
        guard input.isFileURL, let document = PDFDocument(url: input) else {
            throw ToolError.invalid("Could not open \(input.lastPathComponent) as a PDF.")
        }
        guard !document.isLocked || document.unlock(withPassword: password) else {
            throw ToolError.invalid("Enter the correct PDF password.")
        }
        guard document.allowsDocumentAssembly else {
            throw ToolError.invalid("This PDF does not allow page editing.")
        }
        guard document.pageCount > 0 else { throw ToolError.invalid("The PDF has no pages.") }
        return document
    }

    private static func stagingFolder(in directory: URL) throws -> URL {
        guard directory.isFileURL else { throw ToolError.invalid("Choose a local output folder.") }
        let staging = directory.appendingPathComponent(".pdf-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return staging
    }

    private static func writeCopy(_ pages: [PDFPageEdit], from original: PDFDocument, to output: URL) throws {
        let manager = FileManager.default
        guard output.isFileURL, !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a local output PDF path that does not already exist.")
        }
        let staging = try stagingFolder(in: output.deletingLastPathComponent())
        defer { try? manager.removeItem(at: staging) }
        let stagedOutput = staging.appendingPathComponent("Output.pdf")
        try writePages(pages, from: original, to: stagedOutput)
        try Task.checkCancellation()
        try manager.moveItem(at: stagedOutput, to: output)
    }

    private static func writePages(_ pages: [PDFPageEdit], from original: PDFDocument, to output: URL) throws {
        guard !pages.isEmpty else { throw ToolError.invalid("Leave at least one page in the PDF.") }
        guard Set(pages.map(\.pageNumber)).count == pages.count else {
            throw ToolError.invalid("Each page can appear only once in an output PDF.")
        }
        let document = PDFDocument()
        var rotations: [Int] = []
        for edit in pages {
            try Task.checkCancellation()
            guard (1...original.pageCount).contains(edit.pageNumber),
                  let source = original.page(at: edit.pageNumber - 1),
                  let page = source.copy() as? PDFPage else {
                throw ToolError.invalid("Could not read PDF page \(edit.pageNumber).")
            }
            let originalRotation = page.rotation
            guard originalRotation.isMultiple(of: 90) else {
                throw ToolError.invalid("PDF page \(edit.pageNumber) has an unsupported rotation.")
            }
            let rotation = ((originalRotation % 360 + (edit.quarterTurns % 4) * 90) % 360 + 360) % 360
            if rotation != originalRotation { page.rotation = rotation }
            document.insert(page, at: document.pageCount)
            rotations.append(rotation)
        }
        try Task.checkCancellation()
        guard document.write(to: output), let exported = PDFDocument(url: output),
              exported.pageCount == pages.count,
              rotations.enumerated().allSatisfy({ exported.page(at: $0.offset)?.rotation == $0.element }) else {
            throw ToolError.invalid("Could not verify the page count and rotation of the exported PDF.")
        }
    }
}
