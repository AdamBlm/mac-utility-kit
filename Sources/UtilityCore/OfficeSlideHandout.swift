import CoreGraphics
import Foundation
import PDFKit

public enum OfficeSlideLayout: Int, CaseIterable, Identifiable, Sendable {
    case single = 1, two = 2, four = 4, six = 6

    public var id: Self { self }
    public var title: String { self == .single ? "Individual slides" : "\(rawValue) slides per page" }
}

enum OfficeSlideHandout {
    static func write(_ slides: PDFDocument, indices: [Int], to output: URL,
                      layout: OfficeSlideLayout, paper: PDFPrintPaper) throws -> Int {
        let columns = layout == .two ? 1 : 2
        let slots = layout.rawValue
        let rows = slots / columns
        guard !indices.isEmpty, rows > 0 else { throw ToolError.invalid("Choose a slide range and a handout layout.") }
        var paperBounds = CGRect(origin: .zero, size: paper.size)
        guard let canvas = CGContext(output as CFURL, mediaBox: &paperBounds, nil) else {
            throw ToolError.invalid("Could not create the handout PDF.")
        }
        let margin = 30.0
        let gap = 15.0
        let width = (paperBounds.width - 2 * margin - gap * Double(columns - 1)) / Double(columns)
        let height = (paperBounds.height - 2 * margin - gap * Double(rows - 1)) / Double(rows)
        for (position, index) in indices.enumerated() {
            try Task.checkCancellation()
            guard let page = slides.page(at: index), let reference = page.pageRef else {
                throw ToolError.invalid("Could not open slide \(index + 1).")
            }
            let slot = position % slots
            if slot == 0 { canvas.beginPDFPage(nil) }
            let column = slot % columns
            let row = slot / columns
            let frame = CGRect(x: margin + Double(column) * (width + gap),
                               y: paperBounds.height - margin - height - Double(row) * (height + gap),
                               width: width, height: height)
            try draw(page, reference: reference, within: frame, on: canvas)
            if slot == slots - 1 || position == indices.count - 1 { canvas.endPDFPage() }
        }
        canvas.closePDF()
        let pages = (indices.count + slots - 1) / slots
        guard let verified = PDFDocument(url: output), verified.pageCount == pages else {
            throw ToolError.invalid("Could not verify the printed handout page count.")
        }
        return pages
    }

    static func writeSelection(_ slides: PDFDocument, indices: [Int], to output: URL) throws {
        guard let canvas = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw ToolError.invalid("Could not create the selected slide PDF.")
        }
        for index in indices {
            try Task.checkCancellation()
            guard let page = slides.page(at: index), let reference = page.pageRef else {
                throw ToolError.invalid("Could not open slide \(index + 1).")
            }
            var bounds = CGRect(origin: .zero, size: PDFSigning.visibleSize(for: reference))
            let media = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
            canvas.beginPDFPage([kCGPDFContextMediaBox: media] as CFDictionary)
            try draw(page, reference: reference, within: bounds, on: canvas)
            canvas.endPDFPage()
        }
        canvas.closePDF()
    }

    private static func draw(_ page: PDFPage, reference: CGPDFPage, within frame: CGRect, on canvas: CGContext) throws {
        let size = PDFSigning.visibleSize(for: reference)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ToolError.invalid("This slide has no readable page size.")
        }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let placed = CGRect(x: frame.midX - size.width * scale / 2, y: frame.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        canvas.saveGState()
        canvas.clip(to: placed)
        canvas.translateBy(x: placed.minX, y: placed.minY)
        canvas.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: canvas)
        canvas.restoreGState()
        let transform = reference.getDrawingTransform(.cropBox, rect: placed, rotate: 0, preserveAspectRatio: true)
        for annotation in page.annotations {
            if let link = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
                let hotArea = annotation.bounds.applying(transform).intersection(placed)
                if !hotArea.isNull, !hotArea.isEmpty { canvas.setURL(link as CFURL, for: hotArea) }
            }
        }
    }

}
