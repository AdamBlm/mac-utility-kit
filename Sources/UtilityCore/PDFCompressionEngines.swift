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
        if options.preset == .higherQuality, hasQPDF { return [lossless] }
        let traits = try imageTraits(in: document)
        var result: [PDFCompressionOptions] = []
        if hasQPDF {
            result.append(lossless)
            if traits.hasImages && traits.allowsImageChanges {
                var jpeg = options
                jpeg.engine = .qpdf
                result.append(jpeg)
            }
        }
        if hasGhostscript && options.preset != .higherQuality && traits.canDownsample {
            var images = options
            images.engine = .ghostscript
            result.append(images)
        }
        guard !result.isEmpty else {
            if traits.canDownsample {
                throw ToolError.invalid("Set up qpdf for lossless Higher Quality compression, or choose Balanced to try image compression.")
            }
            throw ToolError.invalid("Set up qpdf to safely compress this PDF without rewriting its pages.")
        }
        return result
    }

    static func allowsEmbeddedImageChanges(in document: PDFDocument) throws -> Bool {
        let traits = try imageTraits(in: document)
        return traits.hasImages && traits.allowsImageChanges
    }

    static func canRewriteImages(in document: PDFDocument) throws -> Bool {
        try imageTraits(in: document).canDownsample
    }

    private struct ImageTraits {
        var hasImages = false
        var allowsImageChanges = true
        var preservesDocumentFeatures = true
        var canDownsample: Bool { hasImages && allowsImageChanges && preservesDocumentFeatures }
    }

    private static func imageTraits(in document: PDFDocument) throws -> ImageTraits {
        var traits = ImageTraits()
        traits.preservesDocumentFeatures = (document.outlineRoot?.numberOfChildren ?? 0) == 0
        if let catalog = document.documentRef?.catalog {
            var object: CGPDFObjectRef?
            traits.allowsImageChanges = !CGPDFDictionaryGetObject(catalog, "AcroForm", &object)
            for key in ["StructTreeRoot", "Names", "Collection", "OCProperties", "AF", "PageLabels"] {
                if CGPDFDictionaryGetObject(catalog, key, &object) {
                    traits.preservesDocumentFeatures = false
                    break
                }
            }
        } else {
            traits.preservesDocumentFeatures = false
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index),
                  page.annotations.allSatisfy({ $0.type == "Link" }) else {
                traits.allowsImageChanges = false
                return traits
            }
            if !traits.hasImages, let dictionary = page.pageRef?.dictionary {
                traits.hasImages = containsImages(in: dictionary)
            }
        }
        return traits
    }

    private static func containsImages(in dictionary: CGPDFDictionaryRef, depth: Int = 0) -> Bool {
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
                found = containsImages(in: attributes, depth: depth + 1)
            case "Image":
                if CGPDFDictionaryGetInteger(attributes, "Width", &width),
                   CGPDFDictionaryGetInteger(attributes, "Height", &height) {
                    found = width >= 128 && height >= 128
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
