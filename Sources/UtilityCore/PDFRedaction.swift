import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

public enum PDFRedactionFill: String, CaseIterable, Identifiable, Sendable {
    case black = "Black", white = "White"
    public var id: Self { self }
    var gray: CGFloat { self == .black ? 0 : 1 }
}

public enum PDFRedactionMarkKind: String, Sendable {
    case text = "Text selection", search = "Search match", region = "Rectangle"
}

public struct PDFRedactionMark: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let page: Int
    /// Normalized coordinates from the upper-left of the displayed crop box.
    public let rect: CGRect
    public let kind: PDFRedactionMarkKind

    public init(page: Int, rect: CGRect, kind: PDFRedactionMarkKind) {
        id = UUID()
        self.page = page
        self.rect = rect
        self.kind = kind
    }
}

public struct PDFRedactionSource: Sendable {
    public let url: URL
    public let data: Data
    public let fingerprint: String
    public let pageCount: Int
}

public struct PDFRedactionResult: Sendable {
    public let pageCount: Int
    public let markedPageCount: Int
    public let marks: Int
}

public enum PDFRedaction {
    public static func open(_ url: URL) async throws -> PDFRedactionSource {
        guard url.isFileURL else { throw ToolError.invalid("Choose a local PDF.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let count = values.fileSize, count <= 256 * 1024 * 1024 else {
            throw ToolError.invalid("Choose a PDF file up to 256 MB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024 * 1024 else { throw ToolError.invalid("Choose a PDF file up to 256 MB.") }
        let document = try read(data)
        try Task.checkCancellation()
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PDFRedactionSource(url: url.resolvingSymlinksInPath().standardizedFileURL, data: data, fingerprint: fingerprint, pageCount: document.pageCount)
    }

    public static func search(_ phrase: String, in source: PDFRedactionSource) async throws -> [PDFRedactionMark] {
        let query = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let document = try read(source.data)
        try Task.checkCancellation()
        let matches = document.findString(query, withOptions: .caseInsensitive)
        try Task.checkCancellation()
        return matches.flatMap { marks(for: $0, in: document, kind: .search) }
    }

    public static func marks(
        for selection: PDFSelection, in document: PDFDocument, kind: PDFRedactionMarkKind = .text
    ) -> [PDFRedactionMark] {
        let lineSelections = selection.selectionsByLine()
        return (lineSelections.isEmpty ? [selection] : lineSelections).flatMap { line in
            line.pages.compactMap { page in
                let index = document.index(for: page)
                guard index >= 0, index < document.pageCount, let geometry = try? PDFRedactionGeometry(page),
                      let rect = geometry.normalized(line.bounds(for: page), padding: 1.5) else { return nil }
                return PDFRedactionMark(page: index + 1, rect: rect, kind: kind)
            }
        }
    }

    public static func export(
        _ source: PDFRedactionSource, marks: [PDFRedactionMark], fill: PDFRedactionFill, to output: URL,
        replacingExisting: Bool = false, progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> PDFRedactionResult {
        let manager = FileManager.default
        guard output.isFileURL, !isSource(output, source: source.url),
              replacingExisting || !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a separate local file for the redacted copy.")
        }
        guard !marks.isEmpty else { throw ToolError.invalid("Mark some content before exporting.") }
        guard marks.allSatisfy({ (1...source.pageCount).contains($0.page) &&
            PDFRedactionGeometry.isRect($0.rect) && PDFRedactionGeometry.unit.contains($0.rect) }) else {
            throw ToolError.invalid("Review redaction rectangles inside the page boundaries.")
        }
        let document = try read(source.data)
        let grouped = Dictionary(grouping: marks, by: \.page)
        let staging = output.deletingLastPathComponent().appending(path: ".redact-pdf-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Redacted.pdf")
        guard let writer = CGContext(candidate as CFURL, mediaBox: nil, nil) else {
            throw ToolError.invalid("Could not create a new PDF.")
        }

        var dimensions: [CGSize] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw ToolError.invalid("Could not read page \(index + 1).")
            }
            let geometry = try PDFRedactionGeometry(page)
            let image = try rasterize(page, geometry: geometry, marks: grouped[index + 1] ?? [], fill: fill)
            let outputBox = CGRect(origin: .zero, size: geometry.physicalSize)
            let bytes = withUnsafeBytes(of: outputBox) { Data($0) }
            writer.beginPDFPage([kCGPDFContextMediaBox: bytes] as CFDictionary)
            writer.draw(image, in: outputBox)
            writer.endPDFPage()
            dimensions.append(geometry.physicalSize)
            await progress(0.9 * Double(index + 1) / Double(document.pageCount))
        }
        writer.closePDF()
        try verify(candidate, dimensions: dimensions)
        try Task.checkCancellation()
        guard !isSource(output, source: source.url) else {
            throw ToolError.invalid("Choose a separate local file for the redacted copy.")
        }
        if replacingExisting, manager.fileExists(atPath: output.path) {
            _ = try manager.replaceItemAt(output, withItemAt: candidate)
        } else {
            try manager.moveItem(at: candidate, to: output)
        }
        await progress(1)
        return PDFRedactionResult(pageCount: document.pageCount, markedPageCount: grouped.count, marks: marks.count)
    }

    private static func isSource(_ candidate: URL, source: URL) -> Bool {
        if candidate.resolvingSymlinksInPath().standardizedFileURL == source { return true }
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let original = (try? source.resourceValues(forKeys: key).fileResourceIdentifier) as? NSObject,
              let target = (try? candidate.resourceValues(forKeys: key).fileResourceIdentifier) as? NSObject else { return false }
        return original.isEqual(target)
    }

    private static func read(_ data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data), !document.isEncrypted,
              document.allowsCopying, document.allowsDocumentChanges, document.pageCount > 0 else {
            throw ToolError.invalid("Choose an unencrypted PDF that allows copying and editing.")
        }
        return document
    }

    private static func rasterize(
        _ page: PDFPage, geometry: PDFRedactionGeometry, marks: [PDFRedactionMark], fill: PDFRedactionFill
    ) throws -> CGImage {
        let size = geometry.physicalSize
        let scale = min(4, 4096 / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let pageRef = page.pageRef, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let buffer = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError.invalid("Could not rasterize a PDF page.")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        buffer.setFillColor(CGColor(gray: 1, alpha: 1))
        buffer.fill(bounds)
        buffer.saveGState()
        buffer.clip(to: bounds)
        buffer.concatenate(geometry.pageToDisplay.concatenating(CGAffineTransform(
            scaleX: bounds.width / geometry.displaySize.width, y: bounds.height / geometry.displaySize.height)))
        buffer.drawPDFPage(pageRef)
        buffer.restoreGState()

        buffer.setShouldAntialias(false)
        buffer.setBlendMode(.copy)
        buffer.setFillColor(CGColor(gray: fill.gray, alpha: 1))
        for mark in marks {
            let rect = mark.rect
            let covered = CGRect(x: rect.minX * bounds.width, y: (1 - rect.maxY) * bounds.height,
                                 width: rect.width * bounds.width, height: rect.height * bounds.height)
            buffer.fill(covered.integral.insetBy(dx: -1, dy: -1).intersection(bounds))
        }
        guard let image = buffer.makeImage() else { throw ToolError.invalid("Could not create a sanitized page image.") }
        return image
    }

    private static func verify(_ candidate: URL, dimensions: [CGSize]) throws {
        guard let output = PDFDocument(url: candidate), output.pageCount == dimensions.count,
              let catalog = output.documentRef?.catalog else {
            throw ToolError.invalid("The redacted PDF could not be reopened.")
        }
        for name in ["Metadata", "Names", "AF", "AcroForm", "Outlines", "OpenAction", "AA", "OCProperties", "StructTreeRoot"] {
            var object: CGPDFObjectRef?
            guard !CGPDFDictionaryGetObject(catalog, name, &object) else {
                throw ToolError.invalid("The exported PDF contained unexpected hidden document data.")
            }
        }
        for (index, expected) in dimensions.enumerated() {
            try Task.checkCancellation()
            guard let page = output.page(at: index), page.annotations.isEmpty,
                  (page.string ?? "").isEmpty, page.rotation == 0 else {
                throw ToolError.invalid("Could not verify sanitized content on page \(index + 1).")
            }
            let size = page.bounds(for: .mediaBox).size
            guard abs(size.width - expected.width) < 0.05, abs(size.height - expected.height) < 0.05 else {
                throw ToolError.invalid("Could not verify page geometry on page \(index + 1).")
            }
        }
    }
}
