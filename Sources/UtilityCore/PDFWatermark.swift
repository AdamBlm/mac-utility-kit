import Foundation
import PDFKit

enum PDFWatermark {
    static func open(_ input: URL) throws -> PDFDocument {
        guard input.isFileURL, let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw ToolError.invalid("Could not open this PDF.")
        }
        guard !document.isEncrypted, !document.isLocked else {
            throw ToolError.invalid("Open an unencrypted PDF to add a watermark.")
        }
        guard document.allowsDocumentChanges, document.allowsCopying else {
            throw ToolError.invalid("This PDF does not allow content changes or copying.")
        }
        return document
    }

    static func preview(_ input: URL, page index: Int, mark: WatermarkArtwork, options: WatermarkOptions) throws -> CGImage {
        let document = try open(input)
        let selected = try PageSelection.indices(options.pdfPages, pageCount: document.pageCount)
        guard (1...document.pageCount).contains(index), let page = document.page(at: index - 1) else {
            throw ToolError.invalid("Select a page within the PDF.")
        }
        let size = try pageSize(page)
        let scale = min(1.5, 880 / max(size.width, size.height))
        let raster = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let context = try WatermarkCanvas.bitmap(size: raster)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: raster))
        context.scaleBy(x: raster.width / size.width, y: raster.height / size.height)
        try draw(page, size: size, on: context, mark: selected.contains(index - 1) ? mark : nil, options: options)
        guard let image = context.makeImage() else { throw ToolError.invalid("Could not create a PDF preview.") }
        return image
    }

    static func export(
        _ input: URL, to output: URL, mark: WatermarkArtwork, options: WatermarkOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        let document = try open(input)
        let selected = try Set(PageSelection.indices(options.pdfPages, pageCount: document.pageCount)).sorted()
        guard !selected.isEmpty else { throw ToolError.invalid("Select at least one PDF page.") }
        let manager = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: ".watermark-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let overlay = staging.appending(path: "Marked pages.pdf")
        guard let context = CGContext(overlay as CFURL, mediaBox: nil, nil) else {
            throw ToolError.invalid("Could not start the marked PDF.")
        }
        for (index, pageIndex) in selected.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else { throw ToolError.invalid("Could not open PDF page \(pageIndex + 1).") }
            let size = try pageSize(page)
            var bounds = CGRect(origin: .zero, size: size)
            let mediaBox = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
            try draw(page, size: size, on: context, mark: mark, options: options)
            context.endPDFPage()
            await progress(Double(index + 1) / Double(selected.count + 2))
        }
        context.closePDF()
        guard let replacements = PDFDocument(url: overlay), replacements.pageCount == selected.count else {
            throw ToolError.invalid("Could not read the marked PDF pages.")
        }
        // Preserve original pages that are outside the selected range.
        let expected = document.pageCount
        for (index, pageIndex) in selected.enumerated() {
            guard let page = replacements.page(at: index), let original = document.page(at: pageIndex) else {
                throw ToolError.invalid("Could not assemble the marked PDF.")
            }
            // A PDFPage belongs to one document. Reopen the one-page representation
            // so inserting it does not mutate the source collection mid-loop.
            guard let data = page.dataRepresentation,
                  let independent = PDFDocument(data: data)?.page(at: 0) else {
                throw ToolError.invalid("Could not copy the marked PDF page.")
            }
            preserveWebLinks(from: original, on: independent)
            document.removePage(at: pageIndex)
            document.insert(independent, at: pageIndex)
        }
        let candidate = staging.appending(path: "Watermarked.pdf")
        guard document.pageCount == expected, document.write(to: candidate),
              let verified = PDFDocument(url: candidate), verified.pageCount == expected else {
            throw ToolError.invalid("Could not verify the completed PDF.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return "\(input.lastPathComponent) · \(selected.count) marked page\(selected.count == 1 ? "" : "s") · PDF"
    }

    private static func preserveWebLinks(from original: PDFPage, on replacement: PDFPage) {
        guard let source = original.pageRef else { return }
        let crop = replacement.bounds(for: .cropBox)
        let transform = source.getDrawingTransform(.cropBox, rect: crop, rotate: 0, preserveAspectRatio: true)
        for annotation in original.annotations where annotation.type == "Link" {
            guard let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url,
                  let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { continue }
            let bounds = annotation.bounds.applying(transform).standardized.intersection(crop)
            guard !bounds.isNull, !bounds.isEmpty else { continue }
            let link = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = 0
            link.border = border
            link.action = PDFActionURL(url: url)
            replacement.addAnnotation(link)
        }
    }

    private static func pageSize(_ page: PDFPage) throws -> CGSize {
        guard let reference = page.pageRef else { throw ToolError.invalid("The PDF page has no visible surface.") }
        let size = PDFSigning.visibleSize(for: reference)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ToolError.invalid("The PDF page has invalid bounds.")
        }
        return size
    }

    private static func draw(
        _ page: PDFPage, size: CGSize, on context: CGContext, mark: WatermarkArtwork?, options: WatermarkOptions
    ) throws {
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: size))
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        if let mark {
            try WatermarkCanvas.place(mark, on: size, options: options, context: context)
        }
    }
}
