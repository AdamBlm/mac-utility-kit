import Foundation
import PDFKit
import AppKit
import UniformTypeIdentifiers
import cmark_gfm

public enum SpeechDocument {
    public static func load(_ url: URL) async throws -> String {
        try await load(url, renderMarkdown: false)
    }

    public static func loadForSpeech(_ url: URL) async throws -> String {
        try await load(url, renderMarkdown: true)
    }

    private static func load(_ url: URL, renderMarkdown: Bool) async throws -> String {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ToolError.invalid("Choose a local document.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= 24 * 1024 * 1024 else {
            throw ToolError.invalid("Choose a local document under 24 MB.")
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let markdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
        let text: String
        if type?.conforms(to: .pdf) == true {
            text = try extractPDF(url)
        } else if type?.conforms(to: .rtf) == true {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            text = try readRTF(data)
        } else if type?.conforms(to: .plainText) == true || markdown {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let decoded: String
            if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
               let utf16 = String(data: data, encoding: .utf16) {
                decoded = utf16
            } else if let utf8 = String(data: data, encoding: .utf8) {
                decoded = utf8
            } else {
                throw ToolError.invalid("The text file must use UTF-8 or UTF-16 with a byte order mark.")
            }
            text = markdown && renderMarkdown ? try readMarkdown(decoded) : decoded
        } else {
            throw ToolError.invalid("Choose a TXT, Markdown, RTF or PDF document.")
        }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("This document does not contain readable text.")
        }
        guard text.utf8.count <= 2 * 1024 * 1024 else {
            throw ToolError.invalid("Open a document with less than 2 MB of extracted text.")
        }
        return text
    }

    private static func extractPDF(_ url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked else {
            throw ToolError.invalid("Could not open the PDF. Unlock protected PDFs before opening them here.")
        }
        guard pdf.allowsCopying else {
            throw ToolError.invalid("This PDF restricts text extraction.")
        }
        var pages: [String] = []
        var bytes = 0
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let text = pdf.page(at: index)?.string, !text.isEmpty else { continue }
            bytes += text.utf8.count
            guard bytes <= 2 * 1024 * 1024 else {
                throw ToolError.invalid("Open a PDF with less than 2 MB of extracted text.")
            }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }

    private static func readRTF(_ data: Data) throws -> String {
        try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                              documentAttributes: nil).string
    }

    private static func readMarkdown(_ source: String) throws -> String {
        let size = source.utf8.count
        guard size <= 2 * 1024 * 1024 else {
            throw ToolError.invalid("Open a Markdown document with less than 2 MB of source text.")
        }
        try Task.checkCancellation()
        guard let document = source.withCString({ cmark_parse_document($0, size, CMARK_OPT_VALIDATE_UTF8) }) else {
            throw ToolError.invalid("Could not parse the Markdown document.")
        }
        defer { cmark_node_free(document) }
        guard let iterator = cmark_iter_new(document) else {
            throw ToolError.invalid("Could not read the Markdown document.")
        }
        defer { cmark_iter_free(iterator) }

        var text = ""
        var needsParagraphBreak = false
        while true {
            try Task.checkCancellation()
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let node = cmark_iter_get_node(iterator) else { continue }
            let type = cmark_node_get_type(node)
            if event == CMARK_EVENT_EXIT {
                if type == CMARK_NODE_HEADING || type == CMARK_NODE_PARAGRAPH { needsParagraphBreak = true }
                continue
            }
            switch type {
            case CMARK_NODE_SOFTBREAK:
                text += " "
            case CMARK_NODE_LINEBREAK:
                text += "\n"
            case CMARK_NODE_TEXT, CMARK_NODE_CODE, CMARK_NODE_CODE_BLOCK:
                guard let literal = cmark_node_get_literal(node) else { continue }
                if !text.isEmpty && (needsParagraphBreak || type == CMARK_NODE_CODE_BLOCK) { text += "\n\n" }
                let content = String(cString: literal)
                text += type == CMARK_NODE_CODE_BLOCK ? content.trimmingCharacters(in: .newlines) : content
                needsParagraphBreak = type == CMARK_NODE_CODE_BLOCK
            default:
                break
            }
        }
    }
}
