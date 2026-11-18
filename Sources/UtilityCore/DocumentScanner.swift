import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public struct ScanCorners: Equatable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public static let fullPage = Self(
        topLeft: CGPoint(x: 0, y: 1), topRight: CGPoint(x: 1, y: 1),
        bottomRight: CGPoint(x: 1, y: 0), bottomLeft: .zero
    )

    public var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    public var isValid: Bool {
        let p = points
        guard p.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        return p.indices.allSatisfy { i in
            let a = p[i]
            let b = p[(i + 1) % p.count]
            let c = p[(i + 2) % p.count]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) < -0.001
        }
    }

    public mutating func set(_ point: CGPoint, at index: Int) {
        switch index {
        case 0: topLeft = point
        case 1: topRight = point
        case 2: bottomRight = point
        case 3: bottomLeft = point
        default: break
        }
    }
}

public enum ScanColor: String, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case grayscale = "Grayscale"
    case highContrast = "High Contrast"

    public var id: Self { self }
}

public struct ScannedPage: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let image: CGImage
    public var corners: ScanCorners
    public var rotation = 0
    public var color: ScanColor = .original
}

public enum DocumentScanner {
    public static let pageLimit = 24
    public static let inputLimit = 48 * 1024 * 1024

    public static func load(_ data: Data, name: String) throws -> [ScannedPage] {
        try Task.checkCancellation()
        guard data.count <= inputLimit else { throw ToolError.invalid("Choose an image or scan smaller than 48 MB.") }
        if let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) {
            guard !pdf.isEncrypted, (1...pageLimit).contains(pdf.numberOfPages) else {
                throw ToolError.invalid("Choose an unlocked scan with up to \(pageLimit) pages.")
            }
            return try (1...pdf.numberOfPages).map { number in
                try Task.checkCancellation()
                guard let page = pdf.page(at: number) else { throw ToolError.invalid("Could not read scan page \(number).") }
                let image = try rasterize(page)
                return ScannedPage(name: "\(name) · \(number)", image: image, corners: .fullPage)
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2000
              ] as CFDictionary) else {
            throw ToolError.invalid("Could not read an image or PDF scan from \(name).")
        }
        let detection = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: image).perform([detection])
        try Task.checkCancellation()
        let estimate = detection.results?.first.map {
            ScanCorners(topLeft: $0.topLeft, topRight: $0.topRight, bottomRight: $0.bottomRight, bottomLeft: $0.bottomLeft)
        }
        return [ScannedPage(name: name, image: image, corners: estimate.flatMap { $0.isValid ? $0 : nil } ?? .fullPage)]
    }

    public static func corrected(_ page: ScannedPage) throws -> CGImage {
        guard page.corners.isValid else { throw ToolError.invalid("Position the four corners around one upright page.") }
        var image = CIImage(cgImage: page.image)
        if page.corners != .fullPage {
            let filter = CIFilter.perspectiveCorrection()
            filter.inputImage = image
            let width = image.extent.width
            let height = image.extent.height
            func pixel(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * width, y: point.y * height) }
            filter.topLeft = pixel(page.corners.topLeft)
            filter.topRight = pixel(page.corners.topRight)
            filter.bottomRight = pixel(page.corners.bottomRight)
            filter.bottomLeft = pixel(page.corners.bottomLeft)
            guard let corrected = filter.outputImage else { throw ToolError.invalid("Could not correct the page perspective.") }
            image = corrected
        }
        switch ((page.rotation % 4) + 4) % 4 {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        if page.color != .original {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = 0
            filter.contrast = page.color == .highContrast ? 1.65 : 1
            if let filtered = filter.outputImage { image = filtered }
        }
        let bounds = image.extent.integral
        guard bounds.width >= 1, bounds.height >= 1, bounds.width <= 6000, bounds.height <= 6000,
              let rendered = CIContext().createCGImage(image, from: bounds) else {
            throw ToolError.invalid("The corrected page is empty or too large.")
        }
        return rendered
    }

    public static func export(
        _ pages: [ScannedPage], to output: URL, paper: PDFImagePaper, replacingConfirmedOutput: Bool = false,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        guard (1...pageLimit).contains(pages.count) else { throw ToolError.invalid("Choose one or more scan pages.") }
        let manager = FileManager.default
        let stage = manager.temporaryDirectory.appending(path: ".muk-scan-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        var urls: [URL] = []
        for page in pages {
            try Task.checkCancellation()
            let url = stage.appending(path: "Page-\(urls.count + 1).png")
            let image = try corrected(page)
            guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ToolError.invalid("Could not stage a scan page.")
            }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw ToolError.invalid("Could not encode a scan page.") }
            urls.append(url)
            await progress(Double(urls.count) / Double(pages.count) / 2)
        }
        var options = ImagesToPDFOptions()
        options.paper = paper
        let candidate = replacingConfirmedOutput ? stage.appending(path: "Scan.pdf") : output
        try await ImagesToPDF.export(urls, to: candidate, options: options) { fraction in await progress(0.5 + 0.45 * fraction) }
        if replacingConfirmedOutput {
            try await RecordingFileSave.copy(candidate, to: output)
        }
        await progress(1)
    }

    private static func rasterize(_ page: CGPDFPage) throws -> CGImage {
        let size = PDFSigning.visibleSize(for: page)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ToolError.invalid("Invalid scan page dimensions.")
        }
        let scale = min(2000 / max(size.width, size.height), 3)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError.invalid("Could not allocate a scan image.")
        }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(bounds)
        canvas.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        canvas.drawPDFPage(page)
        guard let image = canvas.makeImage() else { throw ToolError.invalid("Could not render the scan page.") }
        return image
    }
}
