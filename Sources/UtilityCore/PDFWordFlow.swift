import AppKit
import Foundation
import PDFKit

enum PDFWordFlow {
    enum Block: Equatable, Sendable {
        case heading(String)
        case paragraph(String)
        case list(start: Int?, items: [String])
    }

    struct Line {
        let text: String
        let size: CGFloat?
        let bold: Bool
    }

    static func blocks(from extracted: String, reference: PDFPage?, includesOCR: Bool = false) -> [Block] {
        let native = reference?.attributedString.map(styledLines) ?? []
        let lines: [Line]
        if !includesOCR, !native.isEmpty {
            lines = native
        } else {
            let styles = Dictionary(grouping: native) { normalized($0.text) }
            lines = extracted.components(separatedBy: .newlines).map { text in
                let style = styles[normalized(text)]?.first
                return Line(text: text, size: style?.size, bold: style?.bold ?? false)
            }
        }
        let sizes = lines.filter { $0.text.split(separator: " ").count > 3 }.compactMap(\.size).sorted()
        let baseline = sizes.isEmpty ? nil : sizes[sizes.count / 2]
        var result: [Block] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listStart: Int?
        func finishParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph.removeAll() }
        }
        func finishList() {
            if !listItems.isEmpty { result.append(.list(start: listStart, items: listItems)) }
            listItems.removeAll()
            listStart = nil
        }

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                finishParagraph()
                finishList()
            } else if let bullet = listItem(text) {
                finishParagraph()
                if !listItems.isEmpty, listStart.map({ $0 + listItems.count }) != bullet.number { finishList() }
                if listItems.isEmpty { listStart = bullet.number }
                listItems.append(bullet.body)
            } else if isHeading(text, line: line, baseline: baseline) {
                finishParagraph()
                finishList()
                result.append(.heading(text))
            } else {
                finishList()
                paragraph.append(text)
            }
        }
        finishParagraph()
        finishList()
        if result.isEmpty, !extracted.isEmpty { return [.paragraph(extracted)] }
        return result
    }

    static func html(_ pages: [[Block]]) -> String {
        var lines = ["<!doctype html><html><head><meta charset=\"utf-8\"></head><body>"]
        for page in pages {
            for block in page {
                switch block {
                case .heading(let text): lines.append("<h1>\(escape(text))</h1>")
                case .paragraph(let text): lines.append("<p>\(escape(text))</p>")
                case .list(let start, let items):
                    let tag = start == nil ? "ul" : "ol"
                    let indentation = start.map { " start=\"\($0)\"" } ?? ""
                    let children = items.map { "<li>\(escape($0))</li>" }.joined()
                    lines.append("<\(tag)\(indentation)>\(children)</\(tag)>")
                }
            }
        }
        lines.append("</body></html>")
        return lines.joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func styledLines(_ text: NSAttributedString) -> [Line] {
        let string = text.string as NSString
        var cursor = 0
        var lines: [Line] = []
        while cursor < string.length {
            let range = string.lineRange(for: NSRange(location: cursor, length: 0))
            let candidate = string.substring(with: range)
            var size: CGFloat?
            var bold = false
            text.enumerateAttribute(.font, in: range) { value, _, _ in
                guard let font = value as? NSFont else { return }
                size = max(size ?? 0, font.pointSize)
                bold = bold || font.fontDescriptor.symbolicTraits.contains(.bold)
            }
            lines.append(Line(text: candidate, size: size, bold: bold))
            cursor = NSMaxRange(range)
        }
        return lines
    }

    private static func isHeading(_ text: String, line: Line, baseline: CGFloat?) -> Bool {
        guard text.count <= 120, text.split(separator: " ").count <= 12 else { return false }
        if let size = line.size, let baseline, size >= max(baseline * 1.28, baseline + 3) { return true }
        if line.bold, let size = line.size, let baseline, size >= baseline + 1,
           !text.hasSuffix(".") { return true }
        return text.wholeMatch(of: /(?i)(chapter|section|appendix)\s+[\w\dIVX]+\b.*?/) != nil
    }

    private static func listItem(_ text: String) -> (number: Int?, body: String)? {
        if let match = text.wholeMatch(of: /^[•●▪◦‣–-]\s+(.+)$/) { return (nil, String(match.1)) }
        if let match = text.wholeMatch(of: /^(\d{1,3})[.)]\s+(.+)$/), let number = Int(match.1) { return (number, String(match.2)) }
        return nil
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\u{0}", with: "")
    }
}
