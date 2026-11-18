import Foundation
import PDFKit
import UniformTypeIdentifiers

public enum DocumentSummarizer {
    private static let chunkBytes = 2_600
    private static let maxChunks = 16
    private static let maximumPDFPages = 40

    public enum Length: String, CaseIterable, Identifiable, Sendable {
        case brief = "Brief"
        case detailed = "Detailed"
        public var id: Self { self }
    }

    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case paragraph = "Paragraph"
        case bullets = "Bullets"
        public var id: Self { self }
    }

    public enum Source: Sendable {
        case text(String)
        case document(URL, pages: String, password: String)
    }

    public struct Request: Sendable {
        public let source: Source
        public let length: Length
        public let format: Format

        public init(source: Source, length: Length, format: Format) {
            self.source = source
            self.length = length
            self.format = format
        }
    }

    public struct Result: Sendable {
        public let summary: String
        public let omittedPages: [Int]
    }

    public struct Progress: Sendable {
        public let fraction: Double
        public let message: String
    }

    protocol Provider: Sendable {
        func summarize(_ text: String, instruction: String, tokenLimit: Int) async throws -> String
    }

    public static func summarize(
        _ request: Request, progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Result {
        try await summarize(request, using: AppleSystemSummarizer(), progress: progress)
    }

    static func summarize(
        _ request: Request, using provider: any Provider,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Result {
        await progress(Progress(fraction: 0, message: "Reading Source"))
        let (source, omittedPages) = try await load(request.source, progress: progress)
        let chunks = try split(source)
        guard !chunks.isEmpty else {
            throw ToolError.invalid("No readable text was found in the selected source.")
        }
        let finalInstruction = switch (request.length, request.format) {
        case (.brief, .paragraph): "Write one brief paragraph in two or three sentences."
        case (.brief, .bullets): "Write a short list of up to three bullets, using a dash before each item."
        case (.detailed, .paragraph): "Write a detailed summary in two or three short paragraphs."
        case (.detailed, .bullets): "Write a detailed list of up to six bullets, using a dash before each item."
        }
        let finalBudget = request.length == .brief ? 160 : 360
        let summary: String
        if chunks.count == 1 {
            await progress(Progress(fraction: 0.35, message: "Writing Summary"))
            summary = try await generate(chunks[0], instruction: finalInstruction, budget: finalBudget, using: provider)
        } else {
            var notes: [String] = []
            let noteInstruction = "Write compact source notes. Prioritize specific facts, quantities, dates, and decisions."
            for (index, chunk) in chunks.enumerated() {
                await progress(Progress(fraction: 0.2 + 0.55 * Double(index) / Double(chunks.count),
                                        message: "Summarizing Section \(index + 1) of \(chunks.count)"))
                notes.append(try await generate(chunk, instruction: noteInstruction, budget: 130, using: provider))
            }
            await progress(Progress(fraction: 0.78, message: "Combining Sections"))
            var groups = try pack(notes)
            while groups.count > 1 {
                var condensed: [String] = []
                for group in groups {
                    condensed.append(try await generate(group, instruction: noteInstruction, budget: 130, using: provider))
                }
                let next = try pack(condensed)
                guard next.count < groups.count else {
                    throw ToolError.invalid("The section summaries could not fit together. Try a smaller selection.")
                }
                groups = next
            }
            summary = try await generate(groups[0], instruction: finalInstruction, budget: finalBudget, using: provider)
        }
        await progress(Progress(fraction: 1, message: "Summary Ready"))
        return Result(summary: summary, omittedPages: omittedPages)
    }

    private static func load(
        _ source: Source, progress: @Sendable (Progress) async -> Void
    ) async throws -> (String, [Int]) {
        switch source {
        case .text(let text):
            return (text, [])
        case .document(let url, let pages, let password):
            guard url.isFileURL else {
                throw ToolError.invalid("Choose a local PDF, text, or RTF file.")
            }
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ToolError.invalid("Choose a local PDF, text, or RTF file.")
            }
            if values.contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
                guard let pdf = PDFDocument(url: url) else { throw ToolError.invalid("Could not open this PDF.") }
                if pdf.isLocked || (pdf.isEncrypted && !password.isEmpty), !pdf.unlock(withPassword: password) {
                    throw ToolError.invalid("Could not open this PDF. Check the password.")
                }
                let indices = try PageSelection.indices(pages, pageCount: pdf.pageCount)
                guard indices.count <= maximumPDFPages else {
                    throw ToolError.invalid("Select up to \(maximumPDFPages) PDF pages per summary.")
                }
                var options = TextExtractionOptions()
                options.range = pages
                options.password = password
                options.includePageBreaks = false
                let result = try await TextExtraction.extract(url, options: options) { fraction in
                    await progress(Progress(fraction: fraction * 0.2, message: "Reading PDF Pages"))
                }
                let omitted = result.pages.filter {
                    $0.error != nil || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.compactMap(\.pageNumber)
                return (result.text, omitted)
            }
            return (try await SpeechDocument.load(url), [])
        }
    }

    private static var tooLong: ToolError {
        .invalid("This selection is too long to summarize in one pass. Choose fewer pages or a smaller excerpt (up to 40 KiB).")
    }

    private static func split(_ source: String) throws -> [String] {
        guard source.utf8.count <= chunkBytes * maxChunks else { throw tooLong }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            var end = start
            var byteCount = 0
            var breakAt: String.Index?
            while end < text.endIndex {
                let character = text[end]
                let next = text.index(after: end)
                let size = text[end..<next].utf8.count
                guard byteCount + size <= chunkBytes else { break }
                byteCount += size
                end = next
                if byteCount >= chunkBytes * 3 / 4, character.isWhitespace { breakAt = end }
            }
            guard end > start else { throw ToolError.invalid("The source contains a character sequence that exceeds the model window.") }
            let boundary = end == text.endIndex ? end : breakAt ?? end
            let piece = text[start..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            guard chunks.count <= maxChunks else { throw tooLong }
            start = boundary
        }
        return chunks
    }

    private static func pack(_ notes: [String]) throws -> [String] {
        var groups: [String] = []
        var current = ""
        for note in notes {
            guard note.utf8.count <= chunkBytes else {
                throw ToolError.invalid("The model returned a section summary that was too large to combine.")
            }
            if current.isEmpty {
                current = note
            } else if current.utf8.count + 2 + note.utf8.count <= chunkBytes {
                current += "\n\n" + note
            } else {
                groups.append(current)
                current = note
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func generate(
        _ text: String, instruction: String, budget: Int, using provider: any Provider
    ) async throws -> String {
        try Task.checkCancellation()
        let output = try await provider.summarize(text, instruction: instruction, tokenLimit: budget)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !output.isEmpty else { throw ToolError.invalid("The on-device model returned an empty summary.") }
        return output
    }
}
