import Foundation
import PDFKit

enum PDFCompressionEngines {
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
