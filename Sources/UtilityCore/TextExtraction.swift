import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

public struct TextExtractionOptions: Sendable {
    public var language: String?
    public var range = ""
    public var password = ""
    /// Selected region in the displayed image, with origin at its top-left and coordinates in 0...1.
    public var region: CGRect?
    public var includePageBreaks = true
    public var preferEmbeddedText = true

    public init() {}
}

public struct TextExtractionPage: Identifiable, Sendable {
    public let pageNumber: Int?
    public let text: String
    public let error: String?
    public var id: Int { pageNumber ?? 0 }
}

public struct TextExtractionResult: Sendable {
    public let pages: [TextExtractionPage]
    public let text: String
}

public enum TextExtraction {
    public static func languages() throws -> [String] {
        try makeRequest().supportedRecognitionLanguages()
    }

    public static func extract(
        _ input: URL, options: TextExtractionOptions = .init(),
        progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> TextExtractionResult {
        try Task.checkCancellation()
        guard input.isFileURL,
              try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("Choose a local image or PDF.")
        }

        if let region = options.region {
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            guard region.origin.x.isFinite, region.origin.y.isFinite,
                  region.width.isFinite, region.height.isFinite,
                  !region.isEmpty, unit.contains(region) else {
                throw ToolError.invalid("Choose a nonempty region inside the source.")
            }
        }
        if let language = options.language, try !languages().contains(language) {
            throw ToolError.invalid("The selected recognition language is unavailable on this Mac.")
        }

        let type = try input.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .pdf) == true {
            return try await extractPDF(input, options: options, progress: progress)
        }
        let text = try recognize(readImage(input), options: options)
        try Task.checkCancellation()
        await progress(1)
        return TextExtractionResult(pages: [TextExtractionPage(pageNumber: nil, text: text, error: nil)], text: text)
    }

    private static func extractPDF(
        _ input: URL, options: TextExtractionOptions, progress: @Sendable (Double) async -> Void
    ) async throws -> TextExtractionResult {
        let stamp = try PDFSourceStamp.read(input)
        guard let document = PDFDocument(url: stamp.resolved) else {
            throw ToolError.invalid("Could not open this PDF.")
        }
        if document.isLocked || (document.isEncrypted && !options.password.isEmpty),
           !document.unlock(withPassword: options.password) {
            throw ToolError.invalid("Could not open this PDF. Check the password.")
        }
        guard document.allowsCopying else {
            throw ToolError.invalid("This PDF does not allow copying.")
        }
        let indices = try PageSelection.indices(options.range, pageCount: document.pageCount)
        guard !indices.isEmpty else { throw ToolError.invalid("Select at least one page.") }

        var pages: [TextExtractionPage] = []
        for (offset, index) in indices.enumerated() {
            try Task.checkCancellation()
            do {
                guard let page = document.page(at: index) else {
                    throw ToolError.invalid("Could not read page \(index + 1).")
                }
                let text: String
                if options.region == nil, options.preferEmbeddedText, let embedded = page.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !embedded.isEmpty {
                    text = embedded
                } else {
                    let image = try PDFToImages.rasterizeForRecognition(page, pageNumber: index + 1)
                    text = try recognize(image, options: options)
                }
                pages.append(TextExtractionPage(pageNumber: index + 1, text: text, error: nil))
            } catch {
                try Task.checkCancellation()
                pages.append(TextExtractionPage(pageNumber: index + 1, text: "", error: error.localizedDescription))
            }
            await progress(Double(offset + 1) / Double(indices.count))
            try Task.checkCancellation()
            guard (try? PDFSourceStamp.read(input)) == stamp else {
                throw ToolError.invalid("The source PDF changed during text extraction. Try again.")
            }
        }
        let text = pages.filter { $0.error == nil && !$0.text.isEmpty }.map { page in
            options.includePageBreaks ? "Page \(page.id)\n\n\(page.text)" : page.text
        }.joined(separator: options.includePageBreaks ? "\n\u{000C}\n" : "\n\n")
        return TextExtractionResult(pages: pages, text: text)
    }

    private static func readImage(_ input: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4_096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw ToolError.invalid("Could not open this image for text recognition.")
        }
        return image
    }

    public static func recognizeImage(_ image: CGImage, language: String? = nil) async throws -> String {
        if let language, try !languages().contains(language) {
            throw ToolError.invalid("The selected recognition language is unavailable on this Mac.")
        }
        var options = TextExtractionOptions()
        options.language = language
        return try recognize(image, options: options)
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        return request
    }

    private static func recognize(_ image: CGImage, options: TextExtractionOptions) throws -> String {
        try Task.checkCancellation()
        let request = makeRequest()
        if let language = options.language {
            request.recognitionLanguages = [language]
        } else {
            request.automaticallyDetectsLanguage = true
        }
        if let region = options.region {
            request.regionOfInterest = CGRect(x: region.minX, y: 1 - region.maxY,
                                              width: region.width, height: region.height)
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
