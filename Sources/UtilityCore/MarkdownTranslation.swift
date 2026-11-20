import Foundation
import cmark_gfm
import cmark_gfm_extensions

struct MarkdownTranslation: Sendable {
    private typealias Node = UnsafeMutablePointer<cmark_node>
    private enum Shape: Equatable, Sendable {
        case enter(UInt32, [String])
        case leave
    }

    private struct TextNode {
        let node: Node
        let text: String
        let leading: String
        let trailing: String
    }

    private let source: String
    private let shape: [Shape]
    let requests: [String]

    init(_ source: String) throws {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if let first = lines.first {
            let opening = first.first == "\u{FEFF}" ? first.dropFirst() : first
            if (opening == "---" || opening == "+++") && lines.dropFirst().contains(where: {
                $0 == opening || (opening == "---" && $0 == "...")
            }) {
                throw ToolError.invalid("Markdown front matter is unsupported. Remove it before translating the document.")
            }
        }
        let (shape, requests) = try Self.withDocument(source) { document in
            let layout = try Self.inspect(document)
            return (layout.shape, layout.text.map(\.text))
        }
        self.source = source
        self.shape = shape
        self.requests = requests
    }

    func rendering(_ translations: [String]) throws -> String {
        guard translations.count == requests.count else {
            throw ToolError.invalid("The translation did not return all text segments.")
        }
        return try Self.withDocument(source) { document in
            let layout = try Self.inspect(document)
            for (slot, translation) in zip(layout.text, translations) {
                let text = translation.split(whereSeparator: \.isNewline).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !text.utf8.contains(0),
                      cmark_node_set_literal(slot.node, slot.leading + text + slot.trailing) == 1 else {
                    throw ToolError.invalid("The translation returned an empty or invalid Markdown text segment.")
                }
            }
            guard let rendered = cmark_render_commonmark(document, 0, 0) else {
                throw ToolError.invalid("Could not render the translated Markdown.")
            }
            defer { free(rendered) }
            return String(cString: rendered)
        }
    }

    func validate(_ output: String) throws {
        let proposed = try Self.withDocument(output) { try Self.inspect($0).shape }
        guard proposed == shape else {
            throw ToolError.invalid("Keep Markdown formatting, links, and code intact. Edit only the document text.")
        }
    }

    private static func withDocument<Result>(_ source: String, operation: (Node) throws -> Result) throws -> Result {
        guard !source.utf8.contains(0) else { throw ToolError.invalid("Choose Markdown text without null characters.") }
        _ = MarkdownSyntax.registeredExtensions
        let flags = CMARK_OPT_VALIDATE_UTF8 | CMARK_OPT_FOOTNOTES
        guard let parser = cmark_parser_new(flags) else { throw ToolError.invalid("Could not start the Markdown parser.") }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let document = cmark_parser_finish(parser) else { throw ToolError.invalid("Could not parse the Markdown document.") }
        defer { cmark_node_free(document) }
        return try operation(document)
    }

    private static func inspect(_ document: Node) throws -> (shape: [Shape], text: [TextNode]) {
        guard let iterator = cmark_iter_new(document) else { throw ToolError.invalid("Could not inspect the Markdown document.") }
        defer { cmark_iter_free(iterator) }
        var shape: [Shape] = []
        var text: [TextNode] = []
        while true {
            try Task.checkCancellation()
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { return (shape, text) }
            if event == CMARK_EVENT_EXIT { shape.append(.leave); continue }
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            let type = cmark_node_get_type(node)
            let literal = string(cmark_node_get_literal(node))
            var details: [String] = []
            switch type {
            case CMARK_NODE_HTML_BLOCK where literal.trimmingCharacters(in: .whitespacesAndNewlines) == "<!-- end list -->":
                // cmark uses this inert separator to keep a following block outside the list.
                continue
            case CMARK_NODE_TEXT:
                let content = literal.trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty || isAutomaticLink(node, text: literal) {
                    details = [literal]
                } else {
                    let leading = String(literal.prefix { $0.isWhitespace })
                    let trailing = String(literal.reversed().prefix { $0.isWhitespace }.reversed())
                    text.append(TextNode(node: node, text: content, leading: leading, trailing: trailing))
                }
            case CMARK_NODE_HEADING:
                details = [String(cmark_node_get_heading_level(node))]
            case CMARK_NODE_LIST:
                details = [String(cmark_node_get_list_type(node).rawValue),
                           String(cmark_node_get_list_start(node)), String(cmark_node_get_list_tight(node))]
            case CMARK_NODE_LINK, CMARK_NODE_IMAGE:
                details = [string(cmark_node_get_url(node)), string(cmark_node_get_title(node))]
            case CMARK_NODE_CODE:
                details = [literal]
            case CMARK_NODE_CODE_BLOCK:
                details = [literal, string(cmark_node_get_fence_info(node))]
            case CMARK_NODE_DOCUMENT, CMARK_NODE_BLOCK_QUOTE, CMARK_NODE_ITEM, CMARK_NODE_PARAGRAPH,
                 CMARK_NODE_THEMATIC_BREAK, CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK, CMARK_NODE_EMPH, CMARK_NODE_STRONG:
                guard string(cmark_node_get_type_string(node)) != "tasklist" else { throw unsupported(node) }
            default:
                switch string(cmark_node_get_type_string(node)) {
                case "table":
                    let columns = Int(cmark_gfm_extensions_get_table_columns(node))
                    guard columns > 0, let alignments = cmark_gfm_extensions_get_table_alignments(node) else {
                        throw unsupported(node)
                    }
                    details = (0..<columns).map { String(alignments[$0]) }
                case "table_header", "table_row":
                    details = [String(cmark_gfm_extensions_get_table_row_is_header(node))]
                case "table_cell":
                    details = [String(cmark_gfm_extensions_get_table_cell_colspan(node)),
                               String(cmark_gfm_extensions_get_table_cell_rowspan(node))]
                default:
                    throw unsupported(node)
                }
            }
            shape.append(.enter(type.rawValue, details))
        }
    }

    private static func isAutomaticLink(_ node: Node, text: String) -> Bool {
        guard let parent = cmark_node_parent(node), cmark_node_get_type(parent) == CMARK_NODE_LINK,
              cmark_node_first_child(parent) == node, cmark_node_next(node) == nil else { return false }
        let url = string(cmark_node_get_url(parent))
        return text == url || "mailto:" + text == url
    }

    private static func unsupported(_ node: Node) -> ToolError {
        .invalid("Unsupported Markdown \(string(cmark_node_get_type_string(node))) at line \(cmark_node_get_start_line(node)). Use headings, paragraphs, lists, links, images, tables, and code.")
    }

    private static func string(_ value: UnsafePointer<CChar>?) -> String {
        value.map { String(cString: $0) } ?? ""
    }
}
