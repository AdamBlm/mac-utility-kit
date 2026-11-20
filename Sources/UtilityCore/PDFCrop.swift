import CoreGraphics
import Foundation
import PDFKit

public struct PDFCropOffsets: Equatable, Sendable {
    public var top = 0.0
    public var right = 0.0
    public var bottom = 0.0
    public var left = 0.0

    public init() {}

    public func displayedBounds(in size: CGSize) throws -> CGRect {
        guard [top, right, bottom, left, size.width, size.height].allSatisfy({ $0.isFinite && $0 >= 0 }),
              left + right < size.width, top + bottom < size.height else {
            throw ToolError.invalid("Enter nonnegative crop offsets that leave a visible page.")
        }
        return CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
    }
}

public struct PDFCropOptions: Equatable, Sendable {
    public var pages = ""
    public var offsets = PDFCropOffsets()
    public var sourceStamp: PDFSourceStamp?

    public init() {}
}

public enum PDFCrop {
    public static func visibleSize(for page: CGPDFPage) -> CGSize {
        let size = PDFSigning.visibleSize(for: page)
        let unit = pageUnit(page)
        return CGSize(width: size.width * unit, height: size.height * unit)
    }

    private static func pageUnit(_ page: CGPDFPage) -> CGFloat {
        var unit: CGPDFReal = 1
        guard let dictionary = page.dictionary, CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit),
              unit.isFinite, unit > 0 else { return 1 }
        return unit
    }

    public static func box(for page: CGPDFPage, offsets: PDFCropOffsets) throws -> CGRect {
        let size = PDFSigning.visibleSize(for: page)
        let unit = pageUnit(page)
        let physical = try offsets.displayedBounds(in: visibleSize(for: page))
        let topLeft = physical.applying(CGAffineTransform(scaleX: 1 / unit, y: 1 / unit))
        let bottomLeft = CGRect(x: topLeft.minX, y: size.height - topLeft.maxY,
                                width: topLeft.width, height: topLeft.height)
        let transform = page.getDrawingTransform(
            .cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true
        )
        return bottomLeft.applying(transform.inverted()).standardized
    }

    public static func validate(document: PDFDocument, options: PDFCropOptions) throws {
        _ = try cropPlan(document, options: options)
    }

    public static func validateSignatureFields(in document: PDFDocument) throws {
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            if let page = document.page(at: index) { try validateSignatureFields(on: page) }
        }
    }

    private static func validateSignatureFields(on page: PDFPage) throws {
        guard !page.annotations.contains(where: { $0.widgetFieldType == .signature }) else {
            throw ToolError.invalid("This PDF has a signature field. Cropping can invalidate digital signatures.")
        }
    }

    private static func cropPlan(_ document: PDFDocument, options: PDFCropOptions) throws -> [(index: Int, box: CGRect)] {
        guard !document.isEncrypted, document.allowsDocumentChanges else {
            throw ToolError.invalid("Choose an unencrypted PDF that allows document changes.")
        }
        let selected = try PageSelection.indices(options.pages, pageCount: document.pageCount)
        guard !selected.isEmpty else { throw ToolError.invalid("Choose at least one page to crop.") }
        return try selected.map { index in
            guard let reference = document.page(at: index)?.pageRef else {
                throw ToolError.invalid("Could not read page \(index + 1).")
            }
            do {
                return (index, try box(for: reference, offsets: options.offsets))
            } catch {
                throw ToolError.invalid("Page \(index + 1): \(error.localizedDescription)")
            }
        }
    }

    public static func export(
        _ input: URL, to output: URL, options: PDFCropOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard input.isFileURL, output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a readable PDF and a new local output filename.")
        }
        let stamp = try options.sourceStamp ?? PDFSourceStamp.read(input)
        try verifySource(input, stamp: stamp)
        guard let document = PDFDocument(url: stamp.resolved), document.pageCount > 0 else {
            throw ToolError.invalid("Choose a readable PDF and a new local output filename.")
        }
        let planned = try cropPlan(document, options: options)

        var expected: [CGRect] = []
        var rotations: [Int] = []
        var units: [CGFloat] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let reference = page.pageRef else {
                throw ToolError.invalid("Could not read page \(index + 1).")
            }
            try validateSignatureFields(on: page)
            expected.append(reference.getBoxRect(.cropBox))
            rotations.append(page.rotation)
            units.append(pageUnit(reference))
        }

        // Derive every box from the source before changing PDFKit page state.
        for (position, item) in planned.enumerated() {
            try Task.checkCancellation()
            document.page(at: item.index)?.setBounds(item.box, for: .cropBox)
            expected[item.index] = item.box
            await progress(Double(position + 1) / Double(planned.count + 1))
        }

        try verifySource(input, stamp: stamp)
        let manager = FileManager.default
        let directory = output.deletingLastPathComponent().appendingPathComponent(".MacUtilityKit-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let candidate = directory.appendingPathComponent("Cropped.pdf")
        guard document.write(to: candidate), let native = PDFDocument(url: candidate),
              native.pageCount == expected.count else {
            throw ToolError.invalid("Could not reopen the cropped PDF.")
        }
        let changedScale = expected.indices.contains { index in
            guard let reference = native.page(at: index)?.pageRef else { return false }
            return pageUnit(reference) != units[index]
        }
        let verifiedURL: URL
        if changedScale {
            verifiedURL = directory.appendingPathComponent("Cropped with scale.pdf")
            try await PDFCropQPDF.write(stamp.resolved, to: verifiedURL, boxes: planned, directory: directory)
        } else {
            verifiedURL = candidate
        }
        guard let reopened = PDFDocument(url: verifiedURL), reopened.pageCount == expected.count else {
            throw ToolError.invalid("Could not reopen the cropped PDF.")
        }
        for index in expected.indices {
            guard let page = reopened.page(at: index), let reference = page.pageRef,
                  page.rotation == rotations[index] else {
                throw ToolError.invalid("Could not verify the rotation of cropped page \(index + 1).")
            }
            guard pageUnit(reference) == units[index] else {
                throw ToolError.invalid("The cropped PDF did not retain the original physical scale on page \(index + 1).")
            }
            guard sameBounds(reference.getBoxRect(.cropBox), expected[index]) else {
                throw ToolError.invalid("The exported crop on page \(index + 1) could not be verified.")
            }
        }
        try Task.checkCancellation()
        try verifySource(input, stamp: stamp)
        try manager.moveItem(at: verifiedURL, to: output)
        await progress(1)
        return "\(input.lastPathComponent) · Cropped \(planned.count) of \(expected.count) pages"
    }

    private static func verifySource(_ input: URL, stamp: PDFSourceStamp) throws {
        guard (try? PDFSourceStamp.read(input)) == stamp else {
            throw ToolError.invalid("This PDF changed after preview. Refresh the PDF preview before cropping.")
        }
    }

    private static func sameBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        zip([first.minX, first.minY, first.width, first.height],
            [second.minX, second.minY, second.width, second.height])
            .allSatisfy { abs($0 - $1) < 0.02 }
    }
}
