import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PDFImagePaper: String, CaseIterable, Identifiable, Sendable {
    case original = "Original size", a4 = "A4", letter = "Letter", custom = "Custom"
    public var id: Self { self }
}

public enum PDFImageOrientation: String, CaseIterable, Identifiable, Sendable {
    case automatic = "Automatic", portrait = "Portrait", landscape = "Landscape"
    public var id: Self { self }
}

public enum PDFImagePlacement: String, CaseIterable, Identifiable, Sendable {
    case fit = "Fit", fill = "Fill"
    public var id: Self { self }
}

public struct ImagesToPDFOptions: Sendable {
    public var paper: PDFImagePaper = .original
    public var orientation: PDFImageOrientation = .automatic
    public var placement: PDFImagePlacement = .fit
    public var margin: Double = 0
    public var width: Double = 612
    public var height: Double = 792
    public var backgroundRGB: UInt32 = 0xFFFFFF

    public init() {}
}

public struct PDFImageLayout: Sendable {
    public let page: CGRect
    public let printableArea: CGRect
    public let image: CGRect
}

public enum ImagesToPDF {
    public static func layout(_ input: URL, options: ImagesToPDFOptions) throws -> PDFImageLayout {
        let metadata = try readImage(input)
        return try layout(for: metadata.orientedSize, options: options)
    }

    public static func export(
        _ inputs: [URL], to output: URL, options: ImagesToPDFOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        guard !inputs.isEmpty else { throw ToolError.invalid("Choose at least one image.") }
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a local output PDF path that does not already exist.")
        }
        let manager = FileManager.default
        let staging = try PDFConversionStaging.create(in: output.deletingLastPathComponent())
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("Images.pdf")
        guard let context = CGContext(candidate as CFURL, mediaBox: nil, nil) else {
            throw ToolError.invalid("Could not create the output PDF.")
        }
        do {
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                try draw(input, in: context, options: options)
                await progress(Double(index + 1) / Double(inputs.count + 1))
            }
        } catch {
            context.closePDF()
            throw error
        }
        context.closePDF()
        guard let verified = CGPDFDocument(candidate as CFURL), verified.numberOfPages == inputs.count else {
            throw ToolError.invalid("Could not verify the exported PDF.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
    }

    private static func draw(_ input: URL, in context: CGContext, options: ImagesToPDFOptions) throws {
        let metadata = try readImage(input)
        let layout = try layout(for: metadata.orientedSize, options: options)
        guard let image = CGImageSourceCreateThumbnailAtIndex(metadata.source, metadata.index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(metadata.orientedSize.width, metadata.orientedSize.height)
        ] as CFDictionary) else { throw ToolError.invalid("Could not decode \(input.lastPathComponent).") }

        var box = layout.page
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        let rgb = options.backgroundRGB
        context.setFillColor(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                             blue: Double(rgb & 255) / 255, alpha: 1)
        context.fill(layout.page)
        context.saveGState()
        context.clip(to: layout.printableArea)
        context.interpolationQuality = .high
        context.draw(image, in: layout.image)
        context.restoreGState()
        context.endPDFPage()
    }

    private static func readImage(_ input: URL) throws -> (source: CGImageSource, index: Int, orientedSize: CGSize) {
        guard input.isFileURL, let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent) as an image.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height else {
            throw ToolError.invalid("Invalid or oversized image: \(input.lastPathComponent).")
        }
        let swapsAxes = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return (source, index, CGSize(width: swapsAxes ? height : width, height: swapsAxes ? width : height))
    }

    private static func layout(for image: CGSize, options: ImagesToPDFOptions) throws -> PDFImageLayout {
        guard options.margin.isFinite, options.margin >= 0 else {
            throw ToolError.invalid("Enter a nonnegative page margin.")
        }
        var paper = switch options.paper {
        case .original: CGSize(width: image.width + 2 * options.margin, height: image.height + 2 * options.margin)
        case .a4: CGSize(width: 210 * 72 / 25.4, height: 297 * 72 / 25.4)
        case .letter: CGSize(width: 612, height: 792)
        case .custom: CGSize(width: options.width, height: options.height)
        }
        let landscape = options.orientation == .landscape ||
            (options.orientation == .automatic && options.paper != .custom && image.width > image.height)
        if options.paper != .original,
           (landscape && paper.width < paper.height) || (options.orientation == .portrait && paper.width > paper.height) {
            paper = CGSize(width: paper.height, height: paper.width)
        }
        guard paper.width.isFinite, paper.height.isFinite, paper.width <= 14_400, paper.height <= 14_400,
              paper.width > 2 * options.margin, paper.height > 2 * options.margin else {
            throw ToolError.invalid("Choose page dimensions that leave room inside the margins (maximum 14,400 pt per side).")
        }
        let page = CGRect(origin: .zero, size: paper)
        let printable = page.insetBy(dx: options.margin, dy: options.margin)
        let scales = (printable.width / image.width, printable.height / image.height)
        let scale = options.paper == .original || options.placement == .fit
            ? min(scales.0, scales.1) : max(scales.0, scales.1)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return PDFImageLayout(
            page: page, printableArea: printable,
            image: CGRect(x: printable.midX - size.width / 2, y: printable.midY - size.height / 2,
                          width: size.width, height: size.height)
        )
    }
}

enum PDFConversionStaging {
    static func create(in directory: URL) throws -> URL {
        guard directory.isFileURL else { throw ToolError.invalid("Choose a local output folder.") }
        let staging = directory.appendingPathComponent(".pdf-conversion-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return staging
    }
}
