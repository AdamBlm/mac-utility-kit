import Foundation
import PDFKit
import AppKit
import UniformTypeIdentifiers

public enum SpeechDocument {
    public static func load(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ToolError.invalid("Choose a local document.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= 24 * 1024 * 1024 else {
            throw ToolError.invalid("Choose a local document under 24 MB.")
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let text: String
        if type?.conforms(to: .pdf) == true {
            text = try extractPDF(url)
        } else if type?.conforms(to: .rtf) == true {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            text = try readRTF(data)
        } else if type?.conforms(to: .plainText) == true || url.pathExtension.lowercased() == "md" {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
               let decoded = String(data: data, encoding: .utf16) {
                text = decoded
            } else if let decoded = String(data: data, encoding: .utf8) {
                text = decoded
            } else {
                throw ToolError.invalid("The text file must use UTF-8 or UTF-16 with a byte order mark.")
            }
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
}
