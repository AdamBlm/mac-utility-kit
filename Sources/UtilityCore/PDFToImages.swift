import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum PDFPageImageFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG", jpg = "JPEG", heic = "HEIC"
    public var id: Self { self }
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpg: "jpg"
        case .heic: "heic"
        }
    }

    var type: UTType {
        switch self {
        case .png: .png
        case .jpg: .jpeg
        case .heic: .heic
        }
    }
}

public enum PDFImageResolution: String, CaseIterable, Identifiable, Sendable {
    case dpi = "DPI", bounds = "Pixel bounds"
    public var id: Self { self }
}

public struct PDFToImagesOptions: Sendable {
    public var range = ""
    public var password = ""
    public var format: PDFPageImageFormat = .png
    public var resolution: PDFImageResolution = .dpi
    public var dpi = 144
    public var maxWidth = 2_048
    public var maxHeight = 2_048
    public var quality = 0.85
    public var transparent = false
    public var filenamePattern = "{name}-{page}"

    public init() {}
}

public struct PDFPageRasterPlan: Identifiable, Sendable {
    public let pageNumber: Int
    public let filename: String
    public let width: Int
    public let height: Int
    public var id: Int { pageNumber }
}

public enum PDFToImages {
    public static func plans(_ input: URL, options: PDFToImagesOptions) throws -> [PDFPageRasterPlan] {
        try plans(input, document: open(input, password: options.password), options: options)
    }

    public static func export(
        _ input: URL, into directory: URL, options: PDFToImagesOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws -> [URL] {
        try Task.checkCancellation()
        let document = try open(input, password: options.password)
        let plans = try plans(input, document: document, options: options)
        let staging = try PDFConversionStaging.create(in: directory)
        let manager = FileManager.default
        defer { try? manager.removeItem(at: staging) }
        let outputs = plans.map { directory.appendingPathComponent($0.filename) }
        guard outputs.allSatisfy({ !manager.fileExists(atPath: $0.path) }) else {
            throw ToolError.invalid("An image output filename already exists.")
        }
        for (index, plan) in plans.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: plan.pageNumber - 1) else {
                throw ToolError.invalid("Could not read page \(plan.pageNumber).")
            }
            try render(page, plan: plan, options: options, to: staging.appendingPathComponent(plan.filename))
            await progress(Double(index + 1) / Double(plans.count + 1))
        }
        var published: [URL] = []
        do {
            for output in outputs {
                try Task.checkCancellation()
                try manager.moveItem(at: staging.appendingPathComponent(output.lastPathComponent), to: output)
                published.append(output)
            }
        } catch {
            for url in published { try? manager.removeItem(at: url) }
            throw error
        }
        await progress(1)
        return outputs
    }

    private static func open(_ input: URL, password: String) throws -> PDFDocument {
        guard input.isFileURL, let document = PDFDocument(url: input) else {
            throw ToolError.invalid("Could not open this PDF.")
        }
        if document.isLocked || (document.isEncrypted && !password.isEmpty), !document.unlock(withPassword: password) {
            throw ToolError.invalid("Could not open this PDF. Check the password.")
        }
        guard document.allowsCopying else { throw ToolError.invalid("This PDF does not allow copying.") }
        return document
    }

    private static func plans(_ input: URL, document: PDFDocument, options: PDFToImagesOptions) throws -> [PDFPageRasterPlan] {
        guard document.pageCount > 0 else { throw ToolError.invalid("The PDF has no pages.") }
        guard options.format == .png || (options.quality.isFinite && (0...1).contains(options.quality)) else {
            throw ToolError.invalid("Choose a quality between 0 and 100%.")
        }
        guard !options.transparent || options.format == .png else {
            throw ToolError.invalid("Transparent backgrounds require PNG output.")
        }
        let encoderTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard encoderTypes.contains(options.format.type.identifier) else {
            throw ToolError.invalid("No \(options.format.rawValue) image encoder is available.")
        }
        let pages = try PageSelection.indices(options.range, pageCount: document.pageCount)
        guard !pages.isEmpty else { throw ToolError.invalid("Select at least one PDF page.") }
        let pattern = options.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { throw ToolError.invalid("Enter an image filename pattern.") }
        let stem = input.deletingPathExtension().lastPathComponent
        let digits = String(document.pageCount).count
        var used: Set<String> = []
        return try pages.enumerated().map { index, pageIndex in
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex), let pageRef = page.pageRef else {
                throw ToolError.invalid("Could not read page \(pageIndex + 1).")
            }
            let size = try dimensions(of: pageRef, options: options)
            var filename = try filename(pattern: pattern, stem: stem, page: pageIndex + 1,
                                        number: index + 1, digits: digits)
            let ext = "." + options.format.fileExtension
            if !filename.lowercased().hasSuffix(ext) { filename += ext }
            guard used.insert(filename.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ToolError.invalid("The filename pattern repeats an output name. Include {page} or {number}.")
            }
            return PDFPageRasterPlan(pageNumber: pageIndex + 1, filename: filename, width: size.0, height: size.1)
        }
    }

    private static func filename(pattern: String, stem: String, page: Int, number: Int, digits: Int) throws -> String {
        func padded(_ value: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, digits - text.count)) + text
        }
        let tokens = ["{name}": stem, "{page}": padded(page), "{number}": padded(number)]
        var result = ""
        var remaining = pattern[...]
        while let first = remaining.first {
            if first == "{" {
                guard let end = remaining.firstIndex(of: "}"),
                      let value = tokens[String(remaining[...end])] else {
                    throw ToolError.invalid("Use {name}, {page}, or {number} in the filename pattern.")
                }
                result += value
                remaining = remaining[remaining.index(after: end)...]
            } else {
                guard first != "}" else { throw ToolError.invalid("Invalid image filename pattern.") }
                result.append(remaining.removeFirst())
            }
        }
        guard !result.isEmpty, result != ".", result != "..", !result.contains("/"), !result.contains(":"),
              result.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ToolError.invalid("The pattern produces an invalid image filename.")
        }
        return result
    }

    private static func pageUnit(_ page: CGPDFPage) -> Double {
        var unit: CGPDFReal = 1
        guard let dictionary = page.dictionary, CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit),
              unit.isFinite, unit > 0 else { return 1 }
        return unit
    }

    private static func dimensions(of page: CGPDFPage, options: PDFToImagesOptions) throws -> (Int, Int) {
        let crop = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        let swapsAxes = abs(page.rotationAngle % 180) == 90
        return try dimensions(width: swapsAxes ? crop.height : crop.width,
                              height: swapsAxes ? crop.width : crop.height, unit: pageUnit(page), options: options)
    }

    static func rasterizeForRecognition(_ page: PDFPage, pageNumber: Int) throws -> CGImage {
        guard let reference = page.pageRef else { throw ToolError.invalid("Could not read page \(pageNumber).") }
        var options = PDFToImagesOptions()
        options.resolution = .bounds
        options.maxWidth = 4_096
        options.maxHeight = 4_096
        let (width, height) = try dimensions(of: reference, options: options)
        return try rasterize(page, width: width, height: height, transparent: false, pageNumber: pageNumber)
    }

    private static func dimensions(width: Double, height: Double, unit: Double,
                                   options: PDFToImagesOptions) throws -> (Int, Int) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw ToolError.invalid("The PDF page has invalid dimensions.")
        }
        let scale: Double
        switch options.resolution {
        case .dpi:
            guard (1...1_200).contains(options.dpi) else { throw ToolError.invalid("Enter a DPI between 1 and 1,200.") }
            scale = Double(options.dpi) / 72 * unit
        case .bounds:
            guard (1...16_384).contains(options.maxWidth), (1...16_384).contains(options.maxHeight) else {
                throw ToolError.invalid("Enter pixel bounds between 1 and 16,384.")
            }
            scale = min(Double(options.maxWidth) / width, Double(options.maxHeight) / height)
        }
        let outputWidth = max(1, (width * scale).rounded())
        let outputHeight = max(1, (height * scale).rounded())
        guard outputWidth <= 16_384, outputHeight <= 16_384, outputWidth * outputHeight <= 64_000_000 else {
            throw ToolError.invalid("This resolution exceeds the image size limit. Lower the DPI or pixel bounds.")
        }
        return (Int(outputWidth), Int(outputHeight))
    }

    private static func rasterize(
        _ page: PDFPage, width: Int, height: Int, transparent: Bool, pageNumber: Int
    ) throws -> CGImage {
        guard let pageRef = page.pageRef,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: transparent ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                                      : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ToolError.invalid("Could not render page \(pageNumber).") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if !transparent {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
        }
        context.clip(to: rect)
        let crop = pageRef.getBoxRect(.cropBox).intersection(pageRef.getBoxRect(.mediaBox))
        let swapsAxes = abs(pageRef.rotationAngle % 180) == 90
        context.scaleBy(x: rect.width / (swapsAxes ? crop.height : crop.width),
                        y: rect.height / (swapsAxes ? crop.width : crop.height))
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw ToolError.invalid("Could not render page \(pageNumber).") }
        return image
    }

    private static func render(
        _ page: PDFPage, plan: PDFPageRasterPlan, options: PDFToImagesOptions, to output: URL
    ) throws {
        let image = try rasterize(page, width: plan.width, height: plan.height,
                                  transparent: options.transparent, pageNumber: plan.pageNumber)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, options.format.type.identifier as CFString, 1, nil)
        else { throw ToolError.invalid("Could not prepare the image encoder.") }
        var properties: [CFString: Any] = [:]
        if options.format != .png { properties[kCGImageDestinationLossyCompressionQuality] = options.quality }
        if options.resolution == .dpi {
            properties[kCGImagePropertyDPIWidth] = options.dpi
            properties[kCGImagePropertyDPIHeight] = options.dpi
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let reopened = CGImageSourceCreateWithURL(output as CFURL, nil),
              (CGImageSourceGetType(reopened) as String?) == options.format.type.identifier,
              let info = CGImageSourceCopyPropertiesAtIndex(reopened, 0, nil) as? [CFString: Any],
              (info[kCGImagePropertyPixelWidth] as? Int) == plan.width,
              (info[kCGImagePropertyPixelHeight] as? Int) == plan.height
        else { throw ToolError.invalid("Could not encode and verify page \(plan.pageNumber).") }
    }
}
