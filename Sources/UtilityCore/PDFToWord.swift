import Foundation
import PDFKit

public struct PDFToWordOptions: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case flowing = "Flowing Text"
        case layout = "Preserve Layout"
        public var id: Self { self }
    }

    public var mode = Mode.flowing
    public var pages = ""
    public var password = ""
    public var recognizeScans = true
    public var libreOfficeExecutable: URL?

    public init() {}
}

public enum PDFToWord {
    public struct Page: Identifiable, Sendable {
        public let id: Int
        public let text: String
        public let usedOCR: Bool
        public let issue: String?
    }

    public struct Preview: Sendable {
        public let pages: [Page]
        public let warnings: [String]
    }

    private struct Source {
        let pdf: PDFDocument
        let pages: [Int]
        let stamp: DuplicateFileStamp
    }

    public static func optionIssue(_ input: URL, options: PDFToWordOptions) -> String? {
        guard input.isFileURL, input.pathExtension.lowercased() == "pdf" else { return "Choose a local PDF." }
        guard let selection = options.libreOfficeExecutable, selection.isFileURL,
              FileManager.default.isExecutableFile(atPath: LibreOfficeHeadless.binary(for: selection).path) else {
            return "Choose LibreOffice or its soffice executable to export."
        }
        return nil
    }

    public static func preview(
        _ input: URL, options: PDFToWordOptions, progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Preview {
        let source = try open(input, options)
        let result = try await read(input, source: source, options: options, progress: progress)
        try verifySource(input, stamp: source.stamp)
        return result
    }

    public static func export(
        _ input: URL, to output: URL, options: PDFToWordOptions, progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        if let issue = optionIssue(input, options: options) { throw ToolError.invalid(issue) }
        guard let executable = options.libreOfficeExecutable, output.isFileURL,
              consistentOutput(output, input: input) else {
            throw ToolError.invalid("Choose a new local DOCX file.")
        }
        let source = try open(input, options)
        let stage = output.deletingLastPathComponent().appending(path: ".pdf-word-" + UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }

        let candidate: URL
        var unreadable = 0
        var expectsText = false
        if options.mode == .flowing {
            let report = try await read(input, source: source, options: options) { await progress($0 * 0.65) }
            unreadable = report.pages.count { $0.text.isEmpty }
            expectsText = true
            let pages = report.pages.compactMap { page -> [PDFWordFlow.Block]? in
                guard !page.text.isEmpty else { return nil }
                let reference = page.usedOCR ? nil : source.pdf.page(at: page.id - 1)
                return PDFWordFlow.blocks(from: page.text, reference: reference)
            }
            guard !pages.isEmpty else {
                throw ToolError.invalid("No editable text was found. Enable OCR for scanned PDF pages.")
            }
            let html = stage.appending(path: "Flowing.html")
            try Data(PDFWordFlow.html(pages).utf8).write(to: html)
            candidate = try await LibreOfficeHeadless.convert(html, filter: "docx:Office Open XML Text",
                                                                fileExtension: "docx", executable: executable, in: stage)
        } else {
            let pdf = stage.appending(path: "Selected.pdf")
            try writeSelected(source, to: pdf)
            var selected = pdf
            let hasScans = source.pages.contains { index in source.pdf.page(at: index)?.string?.nonemptyText == nil }
            expectsText = source.pages.count > 0 && !source.pages.allSatisfy {
                source.pdf.page(at: $0)?.string?.nonemptyText == nil
            }
            if options.recognizeScans && hasScans {
                let searchable = stage.appending(path: "Searchable.pdf")
                let recognized = try await SearchablePDF.export(pdf, to: searchable, options: .init()) {
                    await progress($0 * 0.65)
                }
                unreadable = recognized.pages.count { $0.status == .failed || $0.status == .noText }
                expectsText = recognized.pages.contains { $0.status == .addedText || $0.status == .alreadySearchable }
                selected = searchable
            } else if hasScans {
                unreadable = source.pages.count { index in source.pdf.page(at: index)?.string?.nonemptyText == nil }
            }
            candidate = try await LibreOfficeHeadless.convert(selected, filter: "docx:Office Open XML Text",
                                                                fileExtension: "docx", executable: executable, in: stage,
                                                                inputFilter: "writer_pdf_import")
        }
        await progress(0.9)
        try await verifyDOCX(candidate, in: stage, expectsText: expectsText)
        try verifySource(input, stamp: source.stamp)
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        let skipped = unreadable == 0 ? "" : " · \(unreadable) without editable text"
        return "\(source.pages.count) source pages · \(options.mode.rawValue) · DOCX" + skipped
    }

    private static func consistentOutput(_ output: URL, input: URL) -> Bool {
        output.pathExtension.lowercased() == "docx" && output.standardizedFileURL != input.standardizedFileURL
            && !FileManager.default.fileExists(atPath: output.path)
    }

    private static func open(_ input: URL, _ options: PDFToWordOptions) throws -> Source {
        try Task.checkCancellation()
        guard input.isFileURL, input.pathExtension.lowercased() == "pdf",
              let stamp = try DuplicateFileIO.inspect(input), stamp.bytes <= 256 * 1024 * 1024,
              let pdf = PDFDocument(url: input) else { throw ToolError.invalid("Choose a readable local PDF up to 256 MB.") }
        if pdf.isLocked || (pdf.isEncrypted && !options.password.isEmpty), !pdf.unlock(withPassword: options.password) {
            throw ToolError.invalid("Could not open this PDF. Check the password.")
        }
        guard pdf.allowsCopying else { throw ToolError.invalid("This PDF does not allow copying.") }
        let pages = try PageSelection.indices(options.pages, pageCount: pdf.pageCount)
        guard !pages.isEmpty, pages.count <= 100 else { throw ToolError.invalid("Choose up to 100 PDF pages.") }
        return Source(pdf: pdf, pages: pages, stamp: stamp)
    }

    private static func read(
        _ input: URL, source: Source, options: PDFToWordOptions, progress: @Sendable (Double) async -> Void
    ) async throws -> Preview {
        var texts: [Int: TextExtractionPage] = [:]
        if options.recognizeScans {
            let scans = source.pages.filter { source.pdf.page(at: $0)?.string?.nonemptyText == nil }
            if !scans.isEmpty {
                var textOptions = TextExtractionOptions()
                textOptions.range = scans.map { String($0 + 1) }.joined(separator: ",")
                textOptions.password = options.password
                let extracted = try await TextExtraction.extract(input, options: textOptions, progress: progress)
                texts = Dictionary(uniqueKeysWithValues: extracted.pages.map { ($0.id, $0) })
            }
        }
        var totalBytes = 0
        var result: [Page] = []
        var warnings: [String] = [
            options.mode == .layout
                ? "Positioned Word text boxes and images approximate the PDF. Fonts, tables, and alignment may change."
                : "Text reflows as Word paragraphs. Heading and list detection is approximate; pictures and complex layout are omitted."
        ]
        var containsAnnotations = false
        for index in source.pages {
            try Task.checkCancellation()
            guard let page = source.pdf.page(at: index) else { throw ToolError.invalid("Could not open PDF page \(index + 1).") }
            containsAnnotations = containsAnnotations || !page.annotations.isEmpty
            let number = index + 1
            let embedded = page.string?.nonemptyText
            let ocr = texts[number]
            let content = embedded ?? ocr?.text.nonemptyText ?? ""
            totalBytes += content.utf8.count
            guard totalBytes <= 4 * 1024 * 1024 else { throw ToolError.invalid("Select fewer pages, up to 4 MB of extracted text.") }
            let issue = ocr?.error ?? (content.isEmpty
                ? (options.recognizeScans ? "No text recognized." : "No embedded text. Enable OCR for scanned pages.") : nil)
            result.append(Page(id: number, text: content, usedOCR: embedded == nil && !content.isEmpty, issue: issue))
        }
        if containsAnnotations {
            warnings.append("Links, notes, signatures, and interactive form controls may be lost.")
        }
        await progress(1)
        return Preview(pages: result, warnings: warnings)
    }

    private static func writeSelected(_ source: Source, to output: URL) throws {
        let subset = PDFDocument()
        for index in source.pages {
            try Task.checkCancellation()
            guard let page = source.pdf.page(at: index)?.copy() as? PDFPage else {
                throw ToolError.invalid("Could not copy PDF page \(index + 1).")
            }
            subset.insert(page, at: subset.pageCount)
        }
        guard subset.write(to: output), let validated = PDFDocument(url: output),
              !validated.isLocked, validated.pageCount == source.pages.count else {
            throw ToolError.invalid("Could not prepare the selected PDF pages.")
        }
    }

    private static func verifyDOCX(_ docx: URL, in stage: URL, expectsText: Bool) async throws {
        try DocumentConversionEngines.verify(docx, format: .docx)
        let entries = try await ArchiveTools.list(docx)
        guard entries.contains(where: { $0.path == "[Content_Types].xml" }),
              let body = entries.first(where: { $0.path == "word/document.xml" && !$0.isDirectory }),
              let size = body.uncompressedSize, (1...32 * 1024 * 1024).contains(size) else {
            throw ToolError.invalid("LibreOffice did not produce a readable Word document.")
        }
        let check = stage.appending(path: "Verification")
        try FileManager.default.createDirectory(at: check, withIntermediateDirectories: false)
        _ = try await ArchiveTools.extract(docx, to: check, selected: [body.id], conflicts: .skip)
        let contents = try XMLDocument(contentsOf: check.appending(path: "word/document.xml"), options: [.nodeLoadExternalEntitiesNever])
        let retainsText = try !expectsText || contents.nodes(forXPath: "//w:t").contains {
            $0.stringValue?.nonemptyText != nil
        }
        guard contents.rootElement()?.localName == "document", retainsText else {
            throw ToolError.invalid("The Word document did not retain editable text.")
        }
    }

    private static func verifySource(_ input: URL, stamp: DuplicateFileStamp) throws {
        guard try DuplicateFileIO.inspect(input) == stamp else {
            throw ToolError.invalid("The source PDF changed during conversion. Reopen it and try again.")
        }
    }
}

private extension String {
    var nonemptyText: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
