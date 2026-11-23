import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct TextExtractionOptions: Sendable {
    public var language: String?
    public var range = ""
    public var password = ""
    /// Selected region in the displayed image, with origin at its top-left and coordinates in 0...1.
    public var region: CGRect?
    public var includePageBreaks = true
    public var preferEmbeddedText = true
    package var includesMixedScanText = false

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
        try VisionTextRecognition.languages()
    }

    public static func extract(
        _ input: URL, options: TextExtractionOptions = .init(),
        progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> TextExtractionResult {
        try Task.checkCancellation()
        guard let resolved = LocalInputFile.regularFile(input) else {
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

        let type = try resolved.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .pdf) == true {
            return try await extractPDF(input, options: options, progress: progress)
        }
        let stamp = try PDFSourceStamp.read(input)
        let source = try imageSource(stamp.resolved)
        if isTIFF(source) {
            return try await extractPages(
                count: CGImageSourceGetCount(source), options: options, progress: progress,
                verifySource: {
                    guard (try? PDFSourceStamp.read(input)) == stamp else {
                        throw ToolError.invalid("The source TIFF changed during text extraction. Try again.")
                    }
                }
            ) { index in
                try await recognize(readImage(source, index: index), options: options)
            }
        }
        let text = try await recognize(readImage(source, index: CGImageSourceGetPrimaryImageIndex(source)), options: options)
        try Task.checkCancellation()
        await progress(1)
        return TextExtractionResult(pages: [TextExtractionPage(pageNumber: nil, text: text, error: nil)], text: text)
    }

    private static func extractPDF(
        _ input: URL, options: TextExtractionOptions, progress: @Sendable (Double) async -> Void
    ) async throws -> TextExtractionResult {
        let stamp = try PDFSourceStamp.read(input)
        let document = try openPDF(stamp.resolved, password: options.password)
        return try await extractPages(
            count: document.pageCount, options: options, progress: progress,
            verifySource: {
                guard (try? PDFSourceStamp.read(input)) == stamp else {
                    throw ToolError.invalid("The source PDF changed during text extraction. Try again.")
                }
            }
        ) { index in
            guard let page = document.page(at: index) else {
                throw ToolError.invalid("Could not read page \(index + 1).")
            }
            if options.region == nil, options.includesMixedScanText {
                var recognition = SearchablePDFOptions()
                recognition.language = options.language
                recognition.skipsSearchablePages = false
                return try await SearchablePDF.recognitionResult(for: page, index: index, options: recognition).text
            }
            if options.region == nil, options.preferEmbeddedText, let embedded = page.string?
                .trimmingCharacters(in: .whitespacesAndNewlines), !embedded.isEmpty {
                return embedded
            }
            let image = try PDFToImages.rasterizeForRecognition(page, pageNumber: index + 1)
            return try await recognize(image, options: options)
        }
    }

    @concurrent
    package static func regionPreviewPages(_ input: URL, range: String, password: String) async throws -> [Int] {
        try Task.checkCancellation()
        guard let resolved = LocalInputFile.regularFile(input) else {
            throw ToolError.invalid("Choose a local image or PDF.")
        }
        let type = try resolved.resourceValues(forKeys: [.contentTypeKey]).contentType
        let count: Int
        if type?.conforms(to: .pdf) == true {
            count = try openPDF(resolved, password: password).pageCount
        } else {
            let source = try imageSource(resolved)
            guard isTIFF(source) else { return [] }
            count = CGImageSourceGetCount(source)
        }
        try Task.checkCancellation()
        let selected = try PageSelection.indices(range, pageCount: count)
        guard !selected.isEmpty else { throw ToolError.invalid("Select at least one page to preview.") }
        return selected.map { $0 + 1 }
    }

    package static func openPDF(_ input: URL, password: String) throws -> PDFDocument {
        guard let resolved = LocalInputFile.regularFile(input), let document = PDFDocument(url: resolved) else {
            throw ToolError.invalid("Could not open this PDF.")
        }
        if document.isLocked || (document.isEncrypted && !password.isEmpty),
           !document.unlock(withPassword: password) {
            throw ToolError.invalid("Could not open this PDF. Check the password.")
        }
        guard document.allowsCopying else {
            throw ToolError.invalid("This PDF does not allow copying.")
        }
        return document
    }

    private static func extractPages(
        count: Int, options: TextExtractionOptions, progress: @Sendable (Double) async -> Void,
        verifySource: () throws -> Void, readText: (Int) async throws -> String
    ) async throws -> TextExtractionResult {
        let indices = try PageSelection.indices(options.range, pageCount: count)
        guard !indices.isEmpty else { throw ToolError.invalid("Select at least one page.") }
        var pages: [TextExtractionPage] = []
        for (offset, index) in indices.enumerated() {
            try Task.checkCancellation()
            do {
                let text = try await readText(index)
                pages.append(TextExtractionPage(pageNumber: index + 1, text: text, error: nil))
            } catch {
                try Task.checkCancellation()
                pages.append(TextExtractionPage(pageNumber: index + 1, text: "", error: error.localizedDescription))
            }
            await progress(Double(offset + 1) / Double(indices.count))
            try Task.checkCancellation()
            try verifySource()
        }
        let text = pages.filter { $0.error == nil && !$0.text.isEmpty }.map { page in
            options.includePageBreaks ? "Page \(page.id)\n\n\(page.text)" : page.text
        }.joined(separator: options.includePageBreaks ? "\n\u{000C}\n" : "\n\n")
        return TextExtractionResult(pages: pages, text: text)
    }

    public static func imagePreview(_ input: URL, pageNumber: Int?, pageRange: String) throws -> CGImage {
        let source = try imageSource(input)
        let index: Int
        if isTIFF(source) {
            index = try previewPageIndex(pageNumber: pageNumber, pageRange: pageRange,
                                         pageCount: CGImageSourceGetCount(source))
        } else {
            index = CGImageSourceGetPrimaryImageIndex(source)
        }
        return try readImage(source, index: index, maximumSize: 600)
    }

    package static func previewPageIndex(pageNumber: Int?, pageRange: String, pageCount: Int) throws -> Int {
        if let pageNumber {
            guard pageNumber > 0, pageNumber <= pageCount else {
                throw ToolError.invalid("This page is unavailable.")
            }
            return pageNumber - 1
        }
        guard let selected = try PageSelection.indices(pageRange, pageCount: pageCount).first else {
            throw ToolError.invalid("Select at least one page to preview.")
        }
        return selected
    }

    private static func imageSource(_ input: URL) throws -> CGImageSource {
        guard let resolved = LocalInputFile.regularFile(input),
              let source = CGImageSourceCreateWithURL(resolved as CFURL, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true else {
            throw ToolError.invalid("Could not open this image for text recognition.")
        }
        return source
    }

    private static func isTIFF(_ source: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(source) else { return false }
        return UTType(type as String)?.conforms(to: .tiff) == true
    }

    private static func readImage(_ source: CGImageSource, index: Int, maximumSize: Int = 4_096) throws -> CGImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else {
            throw ToolError.invalid("Could not decode the image for text recognition.")
        }
        return image
    }

    public static func recognizeImage(_ image: CGImage, language: String? = nil) async throws -> String {
        if let language, try !languages().contains(language) {
            throw ToolError.invalid("The selected recognition language is unavailable on this Mac.")
        }
        var options = TextExtractionOptions()
        options.language = language
        return try await recognize(image, options: options)
    }

    private static func recognize(_ image: CGImage, options: TextExtractionOptions) async throws -> String {
        try await VisionTextRecognition.perform(on: image, language: options.language, region: options.region)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
