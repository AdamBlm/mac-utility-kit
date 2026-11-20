import CoreGraphics
import Foundation
import PDFKit

enum PDFCompressionEngines {
    static func candidates(for document: PDFDocument, options: PDFCompressionOptions) throws -> [PDFCompressionOptions] {
        try validateInput(document, options: options)
        guard options.engine == .automatic else { return [options] }
        var lossless = options
        lossless.engine = .qpdf
        lossless.preset = .higherQuality
        lossless.imageQuality = nil
        let hasQPDF = options.qpdfExecutable.map(ExternalTool.isExecutable) == true
        let hasGhostscript = options.ghostscriptExecutable.map(ExternalTool.isExecutable) == true
        if hasQPDF && (!hasGhostscript || options.preset == .higherQuality) { return [lossless] }
        let canDownsample = try canRewriteImages(in: document)
        if hasGhostscript && canDownsample && options.preset != .higherQuality {
            var images = options
            images.engine = .ghostscript
            if hasQPDF { return [lossless, images] }
            return [images]
        }
        if hasQPDF { return [lossless] }
        if canDownsample {
            throw ToolError.invalid("Set up qpdf for lossless Higher Quality compression, or choose Balanced to reduce image resolution.")
        }
        throw ToolError.invalid("Set up qpdf to safely compress this PDF without rewriting its pages.")
    }

    static func canRewriteImages(in document: PDFDocument) throws -> Bool {
        guard (document.outlineRoot?.numberOfChildren ?? 0) == 0 else { return false }
        if let catalog = document.documentRef?.catalog {
            for key in ["AcroForm", "StructTreeRoot", "Names", "Collection", "OCProperties", "AF"] {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(catalog, key, &object) { return false }
            }
        }
        var hasLargeImage = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), page.annotations.isEmpty else { return false }
            if !hasLargeImage, let dictionary = page.pageRef?.dictionary {
                hasLargeImage = containsLargeImage(in: dictionary)
            }
        }
        return hasLargeImage
    }

    private static func containsLargeImage(in dictionary: CGPDFDictionaryRef, depth: Int = 0) -> Bool {
        guard depth < 5 else { return false }
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let attributes = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            var width: CGPDFInteger = 0
            var height: CGPDFInteger = 0
            guard CGPDFDictionaryGetName(attributes, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Form":
                found = containsLargeImage(in: attributes, depth: depth + 1)
            case "Image":
                if CGPDFDictionaryGetInteger(attributes, "Width", &width),
                   CGPDFDictionaryGetInteger(attributes, "Height", &height) {
                    found = max(width, height) >= 1_000 && min(width, height) >= 500
                }
            default:
                break
            }
            return !found
        }, nil)
        return found
    }

    static func validateInput(_ document: PDFDocument, options: PDFCompressionOptions) throws {
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            for annotation in document.page(at: index)?.annotations ?? [] {
                if annotation.widgetFieldType == .signature {
                    throw ToolError.invalid("Compressing a PDF with a signature field may invalidate its signature.")
                }
                if options.engine == .ghostscript, annotation.type != "Link" {
                    throw ToolError.invalid("DPI reduction may change annotations or form fields. Use qpdf for this PDF.")
                }
            }
        }
    }

    static func run(_ input: URL, to output: URL, options: PDFCompressionOptions) async throws {
        let directory = output.deletingLastPathComponent()
        switch options.engine {
        case .automatic:
            throw ToolError.invalid("The compression engine must be selected before export.")
        case .qpdf:
            guard let executable = options.qpdfExecutable else { throw ToolError.invalid("Choose a qpdf executable.") }
            var flags = ["--object-streams=generate", "--recompress-flate", "--compression-level=9"]
            if !options.isLossless {
                let quality = options.imageQuality ?? options.defaultQuality
                flags += ["--optimize-images", "--jpeg-quality=\(quality)"]
            }
            do {
                try await ExternalTool.run(executable, name: "qpdf", arguments: flags + [input.path, output.path], directory: directory)
            } catch {
                if error.localizedDescription.contains("--jpeg-quality") {
                    throw ToolError.invalid("JPEG image optimization requires qpdf 12.1 or later. Higher Quality supports lossless compression on older qpdf builds.")
                }
                throw error
            }
        case .ghostscript:
            guard let executable = options.ghostscriptExecutable else { throw ToolError.invalid("Choose a Ghostscript executable.") }
            let dpi = options.imageDPI ?? options.defaultDPI
            let quality = options.imageQuality ?? options.defaultQuality
            let factor = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), 0.1 + 1.8 * pow(1 - Double(quality) / 100, 1.7))
            let recipe = "<< /ColorImageDict << /QFactor \(factor) >> /GrayImageDict << /QFactor \(factor) >> >> setdistillerparams"
            try await ExternalTool.run(executable, name: "Ghostscript", arguments: [
                "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sDEVICE=pdfwrite",
                "-dCompatibilityLevel=1.7", "-dAutoRotatePages=/None", "-dPreserveAnnots=true", "-dCompressPages=true",
                "-dPassThroughJPEGImages=false", "-dAutoFilterColorImages=false", "-dAutoFilterGrayImages=false",
                "-dColorImageFilter=/DCTEncode", "-dGrayImageFilter=/DCTEncode",
                "-dDownsampleColorImages=true", "-dDownsampleGrayImages=true", "-dDownsampleMonoImages=true",
                "-dColorImageDownsampleType=/Bicubic", "-dGrayImageDownsampleType=/Bicubic",
                "-dMonoImageDownsampleType=/Subsample", "-dColorImageResolution=\(dpi)",
                "-dGrayImageResolution=\(dpi)", "-dMonoImageResolution=\(dpi)",
                "-sOutputFile=\(output.path)", "-c", "/PreserveAnnotTypes [/Link] def", recipe, "-f", input.path
            ], directory: directory)
        }
    }
}
