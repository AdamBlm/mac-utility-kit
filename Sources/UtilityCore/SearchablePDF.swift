import CoreGraphics
import Foundation
import PDFKit
import NaturalLanguage
import Vision

public struct SearchablePDFOptions: Equatable, Sendable {
    public var language: String?
    public var range = ""
    public var skipsSearchablePages = true

    public init() {}
}

public struct SearchablePDFPageResult: Identifiable, Sendable {
    public enum Status: Sendable {
        case addedText, alreadySearchable, noText, failed
    }

    public let pageNumber: Int
    public let text: String
    public let status: Status
    public let error: String?
    public var id: Int { pageNumber }
}

public struct SearchablePDFReport: Sendable {
    public let pages: [SearchablePDFPageResult]

    public var summary: String {
        let added = pages.filter { $0.status == .addedText }.count
        let searchable = pages.filter { $0.status == .alreadySearchable }.count
        let noText = pages.filter { $0.status == .noText }.count
        let failed = pages.filter { $0.status == .failed }.count
        var results = ["Added text on \(added) page\(added == 1 ? "" : "s")"]
        if searchable > 0 { results.append("\(searchable) already searchable") }
        if noText > 0 { results.append("\(noText) with no recognized text") }
        if failed > 0 { results.append("\(failed) could not be processed") }
        return results.joined(separator: " · ")
    }

    public var warnings: [String] {
        pages.compactMap { page in
            if let error = page.error { return "Page \(page.pageNumber): \(error)" }
            if page.status == .noText { return "Page \(page.pageNumber): No text recognized." }
            return nil
        }
    }
}

public struct SearchablePDFPreview: Sendable {
    public let image: CGImage
    public let result: SearchablePDFPageResult
}

public enum SearchablePDF {
    public static func pageNumbers(_ input: URL, options: SearchablePDFOptions) async throws -> [Int] {
        let pdf = try open(input)
        return try PageSelection.indices(options.range, pageCount: pdf.pageCount).map { $0 + 1 }
    }

    public static func preview(_ input: URL, pageNumber: Int, options: SearchablePDFOptions) async throws -> SearchablePDFPreview {
        let document = try open(input)
        guard pageNumber > 0, let page = document.page(at: pageNumber - 1) else {
            throw ToolError.invalid("Choose an available page.")
        }
        let raster = try SearchablePDFTextLayer.rasterize(page, limit: 4_096)
        let recognized = try recognize(page, raster: raster, index: pageNumber - 1, options: options)
        return SearchablePDFPreview(image: SearchablePDFTextLayer.thumbnail(raster.image), result: recognized.result)
    }

    public static func export(
        _ input: URL, to output: URL, options: SearchablePDFOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> SearchablePDFReport {
        let manager = FileManager.default
        guard output.isFileURL, output.standardizedFileURL != input.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let document = try open(input)
        try validateLanguage(options.language)
        let indices = try PageSelection.indices(options.range, pageCount: document.pageCount)
        guard !indices.isEmpty else { throw ToolError.invalid("Select at least one page.") }
        let staging = output.deletingLastPathComponent().appending(path: ".searchable-pdf-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Searchable.pdf")

        var results: [SearchablePDFPageResult] = []
        var replacements: [Int: PDFPage] = [:]
        for (offset, index) in indices.enumerated() {
            try Task.checkCancellation()
            do {
                guard let page = document.page(at: index) else { throw ToolError.invalid("Could not open this page.") }
                if options.skipsSearchablePages, let embedded = embeddedText(page) {
                    results.append(makeResult(index, text: embedded, status: .alreadySearchable))
                } else {
                    let raster = try SearchablePDFTextLayer.rasterize(page, limit: 4_096)
                    let recognized = try recognize(page, raster: raster, index: index, options: options)
                    if !recognized.lines.isEmpty {
                        let replacement = try SearchablePDFTextLayer.pageWithText(page, raster: raster, lines: recognized.lines)
                        replacements[index] = replacement
                    }
                    results.append(recognized.result)
                }
            } catch {
                try Task.checkCancellation()
                results.append(makeResult(index, text: "", status: .failed, error: error.localizedDescription))
            }
            await progress(0.9 * Double(offset + 1) / Double(indices.count))
        }

        if replacements.isEmpty {
            try manager.copyItem(at: input, to: candidate)
        } else {
            guard !(0..<document.pageCount).contains(where: { index in
                document.page(at: index)?.annotations.contains { $0.type == "Widget" } == true
            }) else {
                throw ToolError.invalid("Searchable export is unavailable for interactive or signed PDF forms.")
            }
            try replacePages(replacements, in: document)
            guard document.write(to: candidate) else { throw ToolError.invalid("Could not save the searchable PDF.") }
            try verify(candidate, pageCount: document.pageCount, replacements: replacements)
        }

        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return SearchablePDFReport(pages: results)
    }

    private static func open(_ input: URL) throws -> PDFDocument {
        guard input.isFileURL, let pdf = PDFDocument(url: input) else {
            throw ToolError.invalid("Could not open a local PDF with pages.")
        }
        guard !pdf.isEncrypted, pdf.allowsCopying, pdf.allowsDocumentChanges else {
            throw ToolError.invalid("This PDF is encrypted or restricts text extraction and document changes.")
        }
        guard pdf.pageCount > 0 else { throw ToolError.invalid("This PDF has no pages.") }
        return pdf
    }

    private static func validateLanguage(_ language: String?) throws {
        if let language, try !TextExtraction.languages().contains(language) {
            throw ToolError.invalid("The selected recognition language is unavailable on this Mac.")
        }
    }

    private static func embeddedText(_ page: PDFPage) -> String? {
        guard let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func recognize(
        _ page: PDFPage, raster: SearchablePDFTextLayer.Raster, index: Int, options: SearchablePDFOptions
    ) throws -> (lines: [SearchablePDFTextLayer.Line], result: SearchablePDFPageResult) {
        let existing = embeddedText(page)
        if options.skipsSearchablePages, let existing {
            return ([], makeResult(index, text: existing, status: .alreadySearchable))
        }
        try validateLanguage(options.language)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let language = options.language { request.recognitionLanguages = [language] }
        else { request.automaticallyDetectsLanguage = true }
        // OCR the unmasked image. PDFKit text geometry alone cannot distinguish
        // visible text from a stale invisible layer over unrelated scan text.
        let recognized = try observations(in: raster.image, using: request)
        let nativeLines = existing == nil ? [] : SearchablePDFTextLayer.embeddedLines(on: page, raster: raster)
        let native = existing == nil ? nil : EmbeddedWords(page: page, raster: raster, lines: nativeLines)
        let lines = try SearchablePDFTextLayer.readingOrder(recognized.flatMap { observation in
            try Task.checkCancellation()
            return native.map { observation.additions(excluding: $0) } ?? [observation.line]
        })
        let status: SearchablePDFPageResult.Status
        if !lines.isEmpty { status = .addedText }
        else if existing != nil { status = .alreadySearchable }
        else { status = .noText }
        let previewLines = SearchablePDFTextLayer.readingOrder(nativeLines + lines).map(\.text)
        let previewText = ((nativeLines.isEmpty ? [existing].compactMap { $0 } : []) + previewLines).joined(separator: "\n")
        return (lines, makeResult(index, text: previewText, status: status))
    }

    private struct OCRObservation {
        let candidate: VNRecognizedText
        let line: SearchablePDFTextLayer.Line

        func additions(excluding embedded: EmbeddedWords) -> [SearchablePDFTextLayer.Line] {
            let text = candidate.string
            if embedded.matchesCompleteObservation(line) { return [] }
            let ranges = Self.wordRanges(in: text)
            var keepStart: String.Index?
            var keepBounds = CGRect.null
            var parts: [SearchablePDFTextLayer.Line] = []
            var removed = false
            var unmatched: [CGRect] = []

            func endRun(at end: String.Index) {
                guard let start = keepStart else { return }
                var trimmedEnd = end
                while trimmedEnd > start, text[text.index(before: trimmedEnd)].isWhitespace {
                    trimmedEnd = text.index(before: trimmedEnd)
                }
                let range = start..<trimmedEnd
                let bounds = (try? candidate.boundingBox(for: range))?.boundingBox ?? keepBounds
                if !range.isEmpty, !bounds.isEmpty {
                    parts.append(.init(text: String(text[range]), bounds: bounds))
                }
                keepStart = nil
                keepBounds = .null
            }

            for (index, range) in ranges.enumerated() {
                let word = String(text[range])
                let bounds = (try? candidate.boundingBox(for: range))?.boundingBox
                if let bounds, embedded.matches(word, bounds: bounds) {
                    removed = true
                    endRun(at: range.lowerBound)
                } else {
                    if keepStart == nil { keepStart = index == 0 ? text.startIndex : range.lowerBound }
                    if let bounds {
                        keepBounds = keepBounds.union(bounds)
                        unmatched.append(bounds)
                    }
                }
            }
            // Conflicting text at the same location may be an old OCR layer.
            // Keep the whole phrase searchable, including words shared by both layers.
            if !removed || embedded.hasPositionalDisagreement(in: line.bounds, unmatched: unmatched) { return [line] }
            endRun(at: text.endIndex)
            return parts
        }

        static func wordRanges(in text: String) -> [Range<String.Index>] {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            var ranges: [Range<String.Index>] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                ranges.append(range)
                return true
            }
            return ranges
        }
    }

    private struct EmbeddedWords {
        let page: PDFPage
        let text: String
        let raster: SearchablePDFTextLayer.Raster
        let words: [String: [NSRange]]
        let lines: [SearchablePDFTextLayer.Line]

        init(page: PDFPage, raster: SearchablePDFTextLayer.Raster, lines: [SearchablePDFTextLayer.Line]) {
            self.page = page
            self.raster = raster
            self.lines = lines
            let text = page.string ?? ""
            self.text = text
            var words: [String: [NSRange]] = [:]
            for range in OCRObservation.wordRanges(in: text) {
                words[Self.key(String(text[range])), default: []].append(NSRange(range, in: text))
            }
            self.words = words
        }

        func matchesCompleteObservation(_ line: SearchablePDFTextLayer.Line) -> Bool {
            // PDFKit can join overlapping content streams without a separating space.
            // A whole multiword observation can still map to the same physical line.
            guard OCRObservation.wordRanges(in: line.text).count > 1 else { return false }
            let expected = raster.pageBounds(for: line.bounds)
            var start = text.startIndex
            while let range = text.range(of: line.text, options: .caseInsensitive, range: start..<text.endIndex) {
                let selection = page.selection(for: NSRange(range, in: text))
                if let actual = selection?.bounds(for: page) {
                    let overlap = actual.intersection(expected)
                    if !overlap.isEmpty,
                       overlap.width * overlap.height >= expected.width * expected.height * 0.6,
                       overlap.width * overlap.height >= actual.width * actual.height * 0.6 {
                        return true
                    }
                }
                start = range.upperBound
            }
            return false
        }

        func hasPositionalDisagreement(in bounds: CGRect, unmatched: [CGRect]) -> Bool {
            guard !unmatched.isEmpty else { return false }
            return lines.contains { line in
                let actual = line.bounds
                let overlap = actual.intersection(bounds)
                guard !overlap.isEmpty, overlap.width * overlap.height >= bounds.width * bounds.height * 0.6 else {
                    return false
                }
                return unmatched.allSatisfy { word in
                    let intersection = word.intersection(actual)
                    return !intersection.isEmpty && intersection.width * intersection.height >= word.width * word.height * 0.6
                }
            }
        }

        func matches(_ word: String, bounds: CGRect) -> Bool {
            guard !bounds.isEmpty, let ranges = words[Self.key(word)] else { return false }
            let wordBox = raster.pageBounds(for: bounds)
            for range in ranges {
                guard let selection = page.selection(for: range) else { continue }
                let overlap = selection.bounds(for: page).intersection(wordBox)
                if !overlap.isEmpty, overlap.width * overlap.height >= wordBox.width * wordBox.height * 0.25 {
                    return true
                }
            }
            return false
        }

        private static func key(_ word: String) -> String {
            word.precomposedStringWithCanonicalMapping.lowercased()
        }
    }

    private static func observations(in image: CGImage, using request: VNRecognizeTextRequest) throws -> [OCRObservation] {
        try Task.checkCancellation()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return OCRObservation(candidate: candidate, line: .init(text: candidate.string, bounds: observation.boundingBox))
        }
    }

    private static func makeResult(
        _ index: Int, text: String, status: SearchablePDFPageResult.Status, error: String? = nil
    ) -> SearchablePDFPageResult {
        SearchablePDFPageResult(pageNumber: index + 1, text: text, status: status, error: error)
    }

    private static func replacePages(_ replacements: [Int: PDFPage], in document: PDFDocument) throws {
        var updates: [() -> Void] = []
        func newDestination(_ destination: PDFDestination) -> PDFDestination? {
            guard let page = destination.page,
                  let replacement = replacements[document.index(for: page)] else { return nil }
            let target = PDFDestination(page: replacement, at: destination.point)
            target.zoom = destination.zoom
            return target
        }
        let outline = document.outlineRoot
        if let root = outline {
            var stack = [root]
            while let item = stack.popLast() {
                if let destination = item.destination, let next = newDestination(destination) {
                    updates.append { item.destination = next }
                }
                for index in 0..<item.numberOfChildren {
                    if let child = item.child(at: index) { stack.append(child) }
                }
            }
        }
        for index in 0..<document.pageCount {
            guard let page = replacements[index] ?? document.page(at: index) else { continue }
            for annotation in page.annotations {
                if let action = annotation.action as? PDFActionGoTo, let destination = newDestination(action.destination) {
                    updates.append { annotation.action = PDFActionGoTo(destination: destination) }
                }
            }
        }
        for (index, replacement) in replacements.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            document.insert(replacement, at: index)
            document.removePage(at: index + 1)
        }
        for update in updates { update() }
        if let outline { document.outlineRoot = outline }
    }

    private static func geometryMatches(_ page: PDFPage, _ expected: PDFPage) -> Bool {
        let actualMedia = page.bounds(for: .mediaBox)
        let expectedMedia = expected.bounds(for: .mediaBox)
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        return boxes.allSatisfy { box in
            page.bounds(for: box).offsetBy(dx: -actualMedia.minX, dy: -actualMedia.minY)
                == expected.bounds(for: box).offsetBy(dx: -expectedMedia.minX, dy: -expectedMedia.minY)
        }
    }

    private static func verify(_ url: URL, pageCount: Int, replacements: [Int: PDFPage]) throws {
        guard let result = PDFDocument(url: url), result.pageCount == pageCount else {
            throw ToolError.invalid("The output PDF could not be reopened with its original page count.")
        }
        for (index, expected) in replacements {
            try Task.checkCancellation()
            guard let page = result.page(at: index), page.rotation == expected.rotation,
                  geometryMatches(page, expected), embeddedText(page) != nil else {
                throw ToolError.invalid("Could not verify searchable text and page geometry on page \(index + 1).")
            }
        }
    }
}
