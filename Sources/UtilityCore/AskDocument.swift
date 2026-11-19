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
        let id = UUID()
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
        fileprivate let indexID: UUID
        fileprivate let question: String
        fileprivate let usesHistory: Bool
        public var hasEvidence: Bool { !citations.isEmpty }
    }

    public struct Turn: Identifiable, Sendable {
        public let id = UUID()
        public let question: String
        public let answer: Answer

        public init(question: String, answer: Answer) {
            self.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
            self.answer = answer
        }
    }

    public enum QuestionMode: String, CaseIterable, Identifiable, Sendable {
        case automatic = "Auto"
        case newTopic = "New Topic"
        case followUp = "Follow-up"

        public var id: Self { self }
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
        func choose(_ question: String, context: [Turn], passages: [Passage]) async throws -> [Evidence]
    }

    public static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
            || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
    }

    package struct PDFScopeStamp: Sendable {
        fileprivate let source: URL
        fileprivate let stamp: DuplicateFileStamp
    }

    @concurrent
    package static func previewPDF(_ input: URL, password: String) async throws -> sending (PDFDocument, PDFScopeStamp) {
        guard isPDF(input) else { throw ToolError.invalid("Choose a PDF to preview its pages.") }
        try Task.checkCancellation()
        let stamp = try inspectInput(input)
        let document = try TextExtraction.openPDF(input, password: password)
        guard (try? inspectInput(input)) == stamp else {
            throw ToolError.invalid("The PDF changed while its pages were opening. Reload the page thumbnails.")
        }
        try Task.checkCancellation()
        return (document, PDFScopeStamp(source: input.standardizedFileURL, stamp: stamp))
    }

    public static func index(
        _ input: URL, pages: String = "", password: String = "",
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Index {
        try await index(input, pages: pages, password: password, reviewedPDF: nil, progress: progress)
    }

    package static func index(
        _ input: URL, pages: String, password: String, reviewedPDF: PDFScopeStamp?,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Index {
        try Task.checkCancellation()
        let stamp = try inspectInput(input)
        if let reviewedPDF, reviewedPDF.source != input.standardizedFileURL || reviewedPDF.stamp != stamp {
            throw ToolError.invalid("The PDF changed after its pages were reviewed. Reload the page thumbnails.")
        }
        let isPDF = isPDF(input)
        let sections: [Section]
        let omitted: [Int]
        await progress(Progress(fraction: 0, message: "Reading document"))
        if isPDF {
            let pdf = try TextExtraction.openPDF(input, password: password)
            try validatePDFScope(pages, count: pdf.pageCount)
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

    package static func validatePDFScope(_ range: String, count: Int) throws {
        let selected = try PageSelection.indices(range, pageCount: count)
        guard !selected.isEmpty else { throw ToolError.invalid("Select at least one PDF page to index.") }
        guard selected.count <= 100 else { throw ToolError.invalid("Choose up to 100 PDF pages to index.") }
    }

    private static func inspectInput(_ input: URL) throws -> DuplicateFileStamp {
        guard input.isFileURL,
              let stamp = try DuplicateFileIO.inspect(input), stamp.bytes <= 125 * 1024 * 1024 else {
            throw ToolError.invalid("Choose a local document under 125 MB.")
        }
        return stamp
    }

    public static func answer(_ rawQuestion: String, in index: Index, after previous: Turn? = nil) async throws -> Answer {
        try await answer(rawQuestion, in: index, history: [previous].compactMap { $0 })
    }

    public static func answer(
        _ rawQuestion: String, in index: Index, history: [Turn], mode: QuestionMode = .automatic
    ) async throws -> Answer {
        try await answer(rawQuestion, in: index, history: history, mode: mode, using: AppleDocumentAnswerModel())
    }

    static func answer(
        _ rawQuestion: String, in index: Index, history: [Turn] = [], mode: QuestionMode = .automatic,
        using model: any Provider
    ) async throws -> Answer {
        try Task.checkCancellation()
        try index.validateSource()
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= 1_000 else {
            throw ToolError.invalid("Enter a question of up to 1,000 UTF-8 bytes.")
        }
        let words = queryTerms(question)
        let usesHistory = switch mode {
        case .automatic: isFollowUp(question, in: index)
        case .newTopic: false
        case .followUp: true
        }
        let context = usesHistory ? followUpContext(history, index: index) : []
        func result(_ citations: [Citation]) -> Answer {
            Answer(citations: citations, indexID: index.id, question: question, usesHistory: usesHistory)
        }
        let ids = try retrievePassages(words, context: context, index: index)
        let passages = ids.compactMap { id in index.passages.indices.contains(id - 1) ? index.passages[id - 1] : nil }
        guard !passages.isEmpty else { return result([]) }
        let evidence = try await model.choose(question, context: context, passages: passages)
        try Task.checkCancellation()
        try index.validateSource()
        let allowed = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        var citations: [Citation] = []
        for item in evidence.prefix(4) {
            guard let passage = allowed[item.passage], let quote = verifiedQuote(item.quote, in: passage.text) else {
                return result([])
            }
            let citation = Citation(location: passage.location, quote: quote)
            if !citations.contains(citation) { citations.append(citation) }
        }
        return result(citations)
    }

    private static func followUpContext(_ history: [Turn], index: Index) -> [Turn] {
        var recent: [Turn] = []
        for turn in history.suffix(8).reversed() {
            guard turn.answer.indexID == index.id,
                  turn.question.utf8.elementsEqual(turn.answer.question.utf8)
            else { break }
            if !turn.answer.usesHistory {
                if turn.answer.hasEvidence { recent.append(turn) }
                break
            }
            if turn.answer.hasEvidence, recent.isEmpty { recent.append(turn) }
        }
        return Array(recent.reversed())
    }

    private static func retrievePassages(_ words: [String], context: [Turn], index: Index) throws -> [Int] {
        let direct = try index.search.retrieve(Array(words.prefix(24)), limit: 5)
        guard !context.isEmpty else { return direct }

        var ids: [Int] = []
        for turn in context.reversed() {
            for citation in turn.answer.citations.prefix(2) {
                if let passage = index.passages.first(where: {
                    $0.location == citation.location && verifiedQuote(citation.quote, in: $0.text) != nil
                }), !ids.contains(passage.id) {
                    ids.append(passage.id)
                    break
                }
            }
        }
        for id in direct.prefix(3) where !ids.contains(id) { ids.append(id) }

        let contextualTerms = context.flatMap { queryTerms($0.question).prefix(8) }
        let related = try index.search.retrieve(Array(contextualTerms.prefix(24)), limit: 5)
        for id in related + direct where ids.count < 5 && !ids.contains(id) { ids.append(id) }
        return ids
    }

    private static func queryTerms(_ text: String) -> [String] {
        let ignored: Set<String> = ["a", "an", "the", "of", "to", "in", "and", "or", "on", "at", "for", "from",
                                    "by", "with", "is", "are", "was", "were", "be", "it", "its", "they", "this",
                                    "that", "does", "do", "did", "what", "which", "who", "when", "where", "why",
                                    "how", "about", "can", "you", "could", "me", "please", "tell", "document"]
        var seen = Set<String>()
        return DocumentPassageSearch.words(text.lowercased()).filter { !ignored.contains($0) && seen.insert($0).inserted }
    }

    private static func isFollowUp(_ text: String, in index: Index) -> Bool {
        let original = DocumentPassageSearch.words(text)
        let words = original.map { $0.lowercased() }
        let references: Set<String> = ["it", "its", "they", "their", "this", "that", "these", "those", "he", "she", "his", "her"]
        let opening = Array(words.prefix(2))
        let about = opening == ["what", "about"] || opening == ["how", "about"]
        guard words.first == "and" || about || words.contains(where: references.contains) || queryTerms(text).isEmpty
        else { return false }

        let namedWords = words.map { word in
            word.hasSuffix("'s") || word.hasSuffix("’s") ? String(word.dropLast(2)) : word
        }
        let namesAHeading = index.sections.contains { section in
            guard case .section(_, let title?) = section.location else { return false }
            let headingWords = DocumentPassageSearch.words(title.lowercased())
            guard !headingWords.isEmpty, headingWords.count <= namedWords.count else { return false }
            return (0...(namedWords.count - headingWords.count)).contains { start in
                namedWords[start..<(start + headingWords.count)].elementsEqual(headingWords)
            }
        }
        if namesAHeading { return false }

        // A new subject can appear after an opener or in the first clause
        // of a compound question, before the later pronoun.
        let questionOpeners: Set<String> = ["what", "which", "who", "when", "where", "why", "how"]
        let auxiliaries: Set<String> = ["is", "was", "are", "were", "did", "does", "do", "has", "have", "had", "will"]
        let subjectOffset: Int?
        if about || (words.count >= 2 && questionOpeners.contains(words[0]) && auxiliaries.contains(words[1])) {
            subjectOffset = 2
        } else {
            subjectOffset = words.first == "and" ? 1 : nil
        }
        if let subjectOffset {
            let subject = original.dropFirst(subjectOffset).drop(while: { $0.lowercased() == "the" }).first
            if subject?.first?.isUppercase == true, !references.contains(subject?.lowercased() ?? "") { return false }
        }
        return true
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
