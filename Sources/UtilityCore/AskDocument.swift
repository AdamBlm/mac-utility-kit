import Foundation
import PDFKit
import UniformTypeIdentifiers

public enum AskDocument {
    public enum Location: Hashable, Sendable {
        case page(Int)
        case section(line: Int, title: String?)

        public var label: String {
            switch self {
            case .page(let page): "Page \(page)"
            case .section(let line, let title):
                title.map { "\($0) · line \(line)" } ?? "Line \(line)"
            }
        }
    }

    public struct Section: Identifiable, Sendable {
        public var id: Location { location }
        public let location: Location
        public let text: String
    }

    public struct Index: Sendable {
        public let source: URL
        public let sections: [Section]
        public let omittedPages: [Int]
        public let isPDF: Bool
        let stamp: DuplicateFileStamp
        let passages: [Passage]
        let search: DocumentPassageSearch

        public func validateSource() throws {
            guard try DuplicateFileIO.inspect(source) == stamp else {
                throw ToolError.invalid("The document changed. Index it again before asking or opening a citation.")
            }
        }
    }

    public struct Citation: Hashable, Identifiable, Sendable {
        public var id: Self { self }
        public let location: Location
        public let quote: String
    }

    public struct Answer: Sendable {
        public let citations: [Citation]
        public var hasEvidence: Bool { !citations.isEmpty }
    }

    public struct Turn: Identifiable, Sendable {
        public let id = UUID()
        public let question: String
        public let answer: Answer

        public init(question: String, answer: Answer) {
            self.question = question
            self.answer = answer
        }
    }

    public struct Progress: Sendable {
        public let fraction: Double
        public let message: String
    }

    struct Passage: Sendable {
        let id: Int
        let location: Location
        let text: String
    }

    struct Evidence: Sendable {
        let passage: Int
        let quote: String
    }

    protocol Provider: Sendable {
        func choose(_ question: String, previous: Turn?, passages: [Passage]) async throws -> [Evidence]
    }

    public static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
            || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
    }

    public static func index(
        _ input: URL, pages: String = "", password: String = "",
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Index {
        try Task.checkCancellation()
        guard input.isFileURL,
              let stamp = try DuplicateFileIO.inspect(input), stamp.bytes <= 125 * 1024 * 1024 else {
            throw ToolError.invalid("Choose a local document under 125 MB.")
        }
        let isPDF = isPDF(input)
        let sections: [Section]
        let omitted: [Int]
        await progress(Progress(fraction: 0, message: "Reading document"))
        if isPDF {
            guard let pdf = PDFDocument(url: input) else { throw ToolError.invalid("Could not open this PDF.") }
            if pdf.isLocked || (pdf.isEncrypted && !password.isEmpty), !pdf.unlock(withPassword: password) {
                throw ToolError.invalid("Could not open this PDF. Check the password.")
            }
            let selectedPages = try PageSelection.indices(pages, pageCount: pdf.pageCount)
            guard !selectedPages.isEmpty, selectedPages.count <= 100 else {
                throw ToolError.invalid("Choose up to 100 PDF pages to index.")
            }
            var options = TextExtractionOptions()
            options.range = pages
            options.password = password
            let extracted = try await TextExtraction.extract(input, options: options) { fraction in
                await progress(Progress(fraction: fraction * 0.80, message: "Reading PDF pages"))
            }
            sections = extracted.pages.compactMap { page in
                guard let number = page.pageNumber, page.error == nil,
                      !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return Section(location: .page(number), text: page.text)
            }
            omitted = extracted.pages.filter {
                $0.error != nil || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.compactMap(\.pageNumber)
        } else {
            let source = try await SpeechDocument.load(input)
            sections = try splitSections(source, markdown: input.pathExtension.lowercased() == "md")
            omitted = []
        }
        guard !sections.isEmpty else { throw ToolError.invalid("No readable text was found in the selected document.") }
        guard sections.reduce(0, { $0 + $1.text.utf8.count }) <= 2 * 1024 * 1024 else {
            throw ToolError.invalid("Choose a smaller selection, up to 2 MB of extracted text.")
        }
        await progress(Progress(fraction: 0.86, message: "Indexing passages"))
        var passages: [Passage] = []
        for section in sections {
            for text in try passageText(section.text) {
                passages.append(Passage(id: passages.count + 1, location: section.location, text: text))
            }
        }
        let search = try DocumentPassageSearch(passages)
        guard try DuplicateFileIO.inspect(input) == stamp else {
            throw ToolError.invalid("The document changed while it was being indexed.")
        }
        try Task.checkCancellation()
        await progress(Progress(fraction: 1, message: "Index ready"))
        return Index(source: input, sections: sections, omittedPages: omitted, isPDF: isPDF,
                     stamp: stamp, passages: passages, search: search)
    }

    public static func answer(_ rawQuestion: String, in index: Index, after previous: Turn? = nil) async throws -> Answer {
        try await answer(rawQuestion, in: index, after: previous, using: AppleDocumentAnswerModel())
    }

    static func answer(
        _ rawQuestion: String, in index: Index, after previous: Turn? = nil, using model: any Provider
    ) async throws -> Answer {
        try Task.checkCancellation()
        try index.validateSource()
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= 1_000 else {
            throw ToolError.invalid("Enter a question of up to 1,000 UTF-8 bytes.")
        }
        let words = queryTerms(question)
        let context = isFollowUp(question) ? previous : nil
        var ids = try index.search.retrieve(Array(words.prefix(24)), limit: context == nil ? 5 : 3)
        if let context, context.answer.hasEvidence, ids.count < 5 {
            let knownTerms = Array(queryTerms(context.question).prefix(8))
            let related = try index.search.retrieve(knownTerms, limit: 5)
            for id in related where ids.count < 5 && !ids.contains(id) { ids.append(id) }
        }
        let passages = ids.compactMap { id in index.passages.indices.contains(id - 1) ? index.passages[id - 1] : nil }
        guard !passages.isEmpty else { return Answer(citations: []) }
        let evidence = try await model.choose(question, previous: context, passages: passages)
        try Task.checkCancellation()
        try index.validateSource()
        let allowed = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        var citations: [Citation] = []
        for item in evidence.prefix(4) {
            guard let passage = allowed[item.passage], let quote = verifiedQuote(item.quote, in: passage.text) else {
                return Answer(citations: [])
            }
            let citation = Citation(location: passage.location, quote: quote)
            if !citations.contains(citation) { citations.append(citation) }
        }
        return Answer(citations: citations)
    }

    private static func queryTerms(_ text: String) -> [String] {
        let ignored: Set<String> = ["a", "an", "the", "of", "to", "in", "and", "or", "on", "at", "for", "from",
                                    "by", "with", "is", "are", "was", "were", "be", "it", "its", "they", "this",
                                    "that", "does", "do", "did", "what", "which", "who", "when", "where", "why",
                                    "how", "about", "can", "you", "could", "me", "please", "tell", "document"]
        var seen = Set<String>()
        return DocumentPassageSearch.words(text.lowercased()).filter { !ignored.contains($0) && seen.insert($0).inserted }
    }

    private static func isFollowUp(_ text: String) -> Bool {
        let words = DocumentPassageSearch.words(text.lowercased())
        let references: Set<String> = ["it", "its", "they", "their", "this", "that", "these", "those", "he", "she", "his", "her"]
        let opening = Array(words.prefix(2))
        return words.first == "and" || opening == ["what", "about"] || opening == ["how", "about"]
            || words.contains(where: references.contains) || queryTerms(text).isEmpty
    }

    private static func verifiedQuote(_ output: String, in passage: String) -> String? {
        let cleaned = normalized(output)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 650,
              let range = passage.range(of: cleaned, options: [.literal]) else { return nil }
        return String(passage[range])
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func passageText(_ source: String) throws -> [String] {
        let words = source.split(whereSeparator: \.isWhitespace)
        var passages: [String] = []
        var start = 0
        while start < words.count {
            try Task.checkCancellation()
            var end = start
            var bytes = 0
            while end < words.count {
                let length = words[end].utf8.count
                if bytes + length + 1 > 950 { break }
                bytes += length + 1
                end += 1
            }
            if end == start {
                // Very long inputs without separators are split at character boundaries.
                let word = words[start]
                var portion = ""
                for character in word {
                    if portion.utf8.count + character.utf8.count > 950 {
                        if !portion.isEmpty { passages.append(portion) }
                        portion = ""
                    }
                    if character.utf8.count <= 950 { portion.append(character) }
                }
                if !portion.isEmpty { passages.append(portion) }
                start += 1
                continue
            }
            passages.append(words[start..<end].joined(separator: " "))
            start = end == words.count ? end : max(start + 1, end - min(12, (end - start) / 4))
        }
        return passages
    }

    private static func splitSections(_ text: String, markdown: Bool) throws -> [Section] {
        var sections: [Section] = []
        var lines: [String] = []
        var lineBytes = 0
        var start = 1
        var title: String?
        func append() {
            let content = lines.joined(separator: "\n")
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(Section(location: .section(line: start, title: title), text: content))
            }
        }
        for (offset, piece) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            try Task.checkCancellation()
            let line = String(piece)
            let heading = markdown ? line.wholeMatch(of: /^#{1,6}\s+(.+)$/).map { String($0.1) } : nil
            if heading != nil || lineBytes + line.utf8.count > 3_500 {
                append()
                lines.removeAll(keepingCapacity: true)
                lineBytes = 0
                start = offset + 1
                if heading != nil { title = heading.map { String($0.prefix(100)) } }
            }
            lines.append(line)
            lineBytes += line.utf8.count + 1
        }
        append()
        return sections
    }
}
