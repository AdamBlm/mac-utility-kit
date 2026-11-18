import CoreGraphics
import Foundation
import PDFKit

public enum OfficePDFKind: String, CaseIterable, Identifiable, Sendable {
    case word, powerPoint, excel

    public var id: Self { self }

    var extensions: Set<String> {
        switch self {
        case .word: ["doc", "docx", "odt", "rtf", "txt", "text"]
        case .powerPoint: ["ppt", "pptx", "odp"]
        case .excel: ["xls", "xlsx", "ods"]
        }
    }

    var filter: String {
        switch self {
        case .word: "writer_pdf_Export"
        case .powerPoint: "impress_pdf_Export"
        case .excel: "calc_pdf_Export"
        }
    }

    var rangeLabel: String {
        switch self {
        case .word, .excel: "pages"
        case .powerPoint: "slides"
        }
    }
}

public struct OfficePDFOptions: Equatable, Sendable {
    public var libreOfficeExecutable: URL?
    public var pageRange = ""
    public var includesHiddenSlides = false
    public var slideLayout = OfficeSlideLayout.single
    public var handoutPaper = PDFPrintPaper.letter
    public var singlePageSheets = false

    public init() {}
}

public enum OfficePDF {
    public struct Preview: Sendable {
        public let pdf: Data
        public let selectedPages: [Int]
        public let totalPages: Int
        public let handoutPDF: Data?
        public let handoutPages: Int
    }

    public static func optionIssue(_ input: URL, kind: OfficePDFKind, options: OfficePDFOptions) -> String? {
        guard input.isFileURL, kind.extensions.contains(input.pathExtension.lowercased()) else {
            return "This file is unsupported for this conversion."
        }
        guard let selection = options.libreOfficeExecutable, selection.isFileURL,
              FileManager.default.isExecutableFile(atPath: LibreOfficeHeadless.binary(for: selection).path) else {
            return "Choose LibreOffice or its soffice executable."
        }
        return nil
    }

    public static func preview(_ input: URL, kind: OfficePDFKind, options: OfficePDFOptions) async throws -> Preview {
        let staging = try makeStaging(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let pdf = try await compose(input, kind: kind, options: options, in: staging)
        let document = try open(pdf)
        let selected = try selected(options, pageCount: document.pageCount)
        try Task.checkCancellation()
        var handout: Data?
        var handoutPages = 0
        if kind == .powerPoint, options.slideLayout != .single {
            let output = staging.appending(path: "Handout.pdf")
            handoutPages = try OfficeSlideHandout.write(document, indices: selected, to: output,
                                                       layout: options.slideLayout, paper: options.handoutPaper)
            handout = try Data(contentsOf: output)
        }
        return Preview(pdf: try Data(contentsOf: pdf), selectedPages: selected.map { $0 + 1 },
                       totalPages: document.pageCount, handoutPDF: handout, handoutPages: handoutPages)
    }

    public static func export(
        _ input: URL, to output: URL, kind: OfficePDFKind, options: OfficePDFOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let manager = FileManager.default
        guard output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local PDF path.")
        }
        let stage = try makeStaging(in: output.deletingLastPathComponent())
        defer { try? manager.removeItem(at: stage) }
        let rendered = try await compose(input, kind: kind, options: options, in: stage)
        await progress(0.75)
        let complete = try open(rendered)
        let pages = try selected(options, pageCount: complete.pageCount)
        let candidate: URL
        let handoutCount: Int?
        if kind == .powerPoint, options.slideLayout != .single {
            candidate = stage.appending(path: "Handout.pdf")
            handoutCount = try OfficeSlideHandout.write(complete, indices: pages, to: candidate,
                                                       layout: options.slideLayout, paper: options.handoutPaper)
        } else if pages.count == complete.pageCount {
            handoutCount = nil
            candidate = rendered
        } else {
            handoutCount = nil
            if kind == .powerPoint, !options.includesHiddenSlides {
                // Impress PageRange indexes the original deck, even when hidden
                // slides are absent from the preview and export sequence.
                candidate = stage.appending(path: "Selected visible slides.pdf")
                try OfficeSlideHandout.writeSelection(complete, indices: pages, to: candidate)
            } else {
                candidate = try await compose(input, kind: kind, options: options, in: stage, pages: pages)
            }
            try verify(try open(candidate), against: complete, selected: pages)
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        let unit = kind.rangeLabel
        let handoutSummary = handoutCount.map { " · \($0) handout page\($0 == 1 ? "" : "s")" } ?? ""
        return "\(input.lastPathComponent) · \(pages.count) \(pages.count == 1 ? String(unit.dropLast()) : unit)\(handoutSummary) · PDF"
    }

    public struct PreviewPage: Sendable {
        public let image: CGImage
        public let size: CGSize
    }

    public static func renderedPage(_ preview: Preview, page index: Int, handout: Bool = false) throws -> PreviewPage {
        let document = try previewDocument(preview, page: index, handout: handout)
        guard let page = document.page(at: index - 1), let pageRef = page.pageRef else {
            throw ToolError.invalid("Could not read the preview page.")
        }
        let size = PDFSigning.visibleSize(for: pageRef)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ToolError.invalid("Could not read the preview page size.")
        }
        let scale = min(1.5, 960 / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let renderer = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError.invalid("Could not allocate the PDF preview.")
        }
        renderer.setFillColor(CGColor(gray: 1, alpha: 1))
        renderer.fill(CGRect(x: 0, y: 0, width: width, height: height))
        renderer.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        page.draw(with: .cropBox, to: renderer)
        guard let image = renderer.makeImage() else { throw ToolError.invalid("Could not render the PDF preview.") }
        return PreviewPage(image: image, size: size)
    }

    private static func previewDocument(_ preview: Preview, page index: Int, handout: Bool) throws -> PDFDocument {
        let data = handout ? preview.handoutPDF : preview.pdf
        let pageCount = handout ? preview.handoutPages : preview.totalPages
        guard pageCount > 0, (1...pageCount).contains(index), let data, let document = PDFDocument(data: data) else {
            throw ToolError.invalid("Choose a valid rendered page.")
        }
        return document
    }

    private static func compose(
        _ input: URL, kind: OfficePDFKind, options: OfficePDFOptions, in staging: URL, pages: [Int]? = nil
    ) async throws -> URL {
        if let issue = optionIssue(input, kind: kind, options: options) { throw ToolError.invalid(issue) }
        let values = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= 256 * 1024 * 1024,
              let executable = options.libreOfficeExecutable else {
            throw ToolError.invalid("Choose a readable document up to 256 MB and a LibreOffice executable.")
        }
        var prepared = input
        var inputFilter: String?
        if kind == .word, ["txt", "text"].contains(input.pathExtension.lowercased()) {
            let text = try DocumentConvert.readText(input)
            prepared = staging.appending(path: "Plain.txt")
            if !FileManager.default.fileExists(atPath: prepared.path) { try Data(text.utf8).write(to: prepared) }
            inputFilter = "Text (encoded):UTF8,LF"
        }
        let filter = try renderFilter(kind, options: options, pages: pages)
        return try await LibreOfficeHeadless.convert(prepared, filter: filter, fileExtension: "pdf",
                                                      executable: executable, in: staging, inputFilter: inputFilter)
    }

    private static func renderFilter(_ kind: OfficePDFKind, options: OfficePDFOptions, pages: [Int]?) throws -> String {
        let boolean = { (value: Bool) in ["type": "boolean", "value": String(value)] }
        var flags = ["ExportBookmarks": boolean(true), "EmbedStandardFonts": boolean(true)]
        if kind == .powerPoint {
            flags["ExportHiddenSlides"] = boolean(options.includesHiddenSlides)
            flags["UseTransitionEffects"] = boolean(false)
        }
        if kind == .excel { flags["SinglePageSheets"] = boolean(options.singlePageSheets) }
        if let pages {
            flags["PageRange"] = ["type": "string", "value": pages.map { String($0 + 1) }.joined(separator: ",")]
        }
        let raw = try JSONSerialization.data(withJSONObject: flags, options: [.sortedKeys])
        return "pdf:\(kind.filter):" + String(decoding: raw, as: UTF8.self)
    }

    private static func open(_ file: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: file), document.pageCount > 0, !document.isLocked else {
            throw ToolError.invalid("LibreOffice did not produce a readable PDF. Check that it can open and print the source.")
        }
        return document
    }

    private static func selected(_ options: OfficePDFOptions, pageCount: Int) throws -> [Int] {
        let selection = try PageSelection.indices(options.pageRange, pageCount: pageCount).sorted()
        guard !selection.isEmpty else { throw ToolError.invalid("Select at least one page or slide.") }
        return selection
    }

    private static func verify(_ subset: PDFDocument, against original: PDFDocument, selected pages: [Int]) throws {
        guard subset.pageCount == pages.count else { throw ToolError.invalid("The PDF page range did not export correctly.") }
        for (index, selected) in pages.enumerated() {
            try Task.checkCancellation()
            guard let before = original.page(at: selected), let after = subset.page(at: index),
                  before.string == after.string,
                  externalLinks(before) == externalLinks(after) else {
                throw ToolError.invalid("Page \(selected + 1) changed its text or external links during export.")
            }
        }
    }

    private static func externalLinks(_ page: PDFPage) -> [String] {
        page.annotations.compactMap { ($0.url ?? ($0.action as? PDFActionURL)?.url)?.absoluteString }.sorted()
    }

    private static func makeStaging(in parent: URL) throws -> URL {
        let stage = parent.appending(path: ".office-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }
}
