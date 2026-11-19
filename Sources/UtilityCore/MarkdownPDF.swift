import Foundation
import cmark_gfm
import cmark_gfm_extensions

public enum MarkdownPDFTheme: String, CaseIterable, Identifiable, Sendable {
    case classic = "Classic"
    case modern = "Modern"
    case technical = "Technical"

    public var id: Self { self }

    fileprivate var typography: (body: String, headings: String, accent: String) {
        switch self {
        case .classic: ("Georgia, serif", "Georgia, serif", "#394673")
        case .modern: ("-apple-system, sans-serif", "-apple-system, sans-serif", "#16586a")
        case .technical: ("-apple-system, sans-serif", "Menlo, monospace", "#553468")
        }
    }
}

public struct MarkdownPDFOptions: Equatable, Sendable {
    public var theme = MarkdownPDFTheme.classic
    public var paper = PDFPrintPaper.a4
    public var margin = PDFPrintMargin.comfortable
    public var imageFolder: URL?

    public init() {}
}

public struct MarkdownPDFDocument: Sendable {
    public let html: String
    public let imageIssues: [String]
    public let options: MarkdownPDFOptions
}

enum MarkdownSyntax {
    static let registeredExtensions: Void = cmark_gfm_core_extensions_ensure_registered()
}

public enum MarkdownPDF {

    public static func prepare(_ markdown: String, options: MarkdownPDFOptions = .init()) async throws -> MarkdownPDFDocument {
        let bytes = markdown.utf8.count
        guard bytes > 0, bytes <= 2_097_152,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("Enter Markdown text up to 2 MB.")
        }
        try Task.checkCancellation()
        let (fragment, issues) = try render(markdown, bytes: bytes, imageFolder: options.imageFolder)
        return MarkdownPDFDocument(html: html(fragment, theme: options.theme), imageIssues: issues, options: options)
    }

    private static func render(_ text: String, bytes: Int, imageFolder: URL?) throws -> (String, [String]) {
        _ = MarkdownSyntax.registeredExtensions
        let flags = CMARK_OPT_VALIDATE_UTF8
        guard let parser = cmark_parser_new(flags) else {
            throw ToolError.invalid("Could not start the Markdown parser.")
        }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        text.withCString { cmark_parser_feed(parser, $0, bytes) }
        guard let document = cmark_parser_finish(parser) else {
            throw ToolError.invalid("Could not parse the Markdown document.")
        }
        defer { cmark_node_free(document) }

        let headingIDs = try MarkdownHeadingAnchors.assign(in: document)
        var images = MarkdownLocalImages(folder: imageFolder)
        for node in resourceNodes(document).reversed() {
            try Task.checkCancellation()
            guard let raw = cmark_node_get_url(node) else { continue }
            let target = String(cString: raw)
            if cmark_node_get_type(node) == CMARK_NODE_IMAGE {
                switch images.resolve(target) {
                case .success(let data):
                    cmark_node_set_url(node, data)
                case .failure(let issue):
                    images.issues.append(issue.localizedDescription)
                    if let replacement = cmark_node_new(CMARK_NODE_TEXT) {
                        cmark_node_set_literal(replacement, "[Image unavailable]")
                        if cmark_node_replace(node, replacement) == 1 {
                            cmark_node_free(node)
                        } else {
                            cmark_node_free(replacement)
                        }
                    }
                }
            } else if target.hasPrefix("#"), let id = String(target.dropFirst()).removingPercentEncoding,
                      headingIDs.contains(id.precomposedStringWithCanonicalMapping) {
                cmark_node_set_url(node, "#" + MarkdownHeadingAnchors.printableID(id.precomposedStringWithCanonicalMapping))
            } else if !safeLink(target) {
                cmark_node_set_url(node, "")
            }
        }
        // Deliberately leave CMARK_OPT_UNSAFE off: rendered HTML cannot include raw HTML or unsafe URLs.
        guard let content = cmark_render_html(document, flags, cmark_parser_get_syntax_extensions(parser)) else {
            throw ToolError.invalid("Could not render the Markdown document.")
        }
        defer { free(content) }
        try Task.checkCancellation()
        return (String(cString: content), Array(images.issues.reversed()))
    }

    private static func resourceNodes(_ document: UnsafeMutablePointer<cmark_node>) -> [UnsafeMutablePointer<cmark_node>] {
        guard let iterator = cmark_iter_new(document) else { return [] }
        defer { cmark_iter_free(iterator) }
        var nodes: [UnsafeMutablePointer<cmark_node>] = []
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { return nodes }
            if event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) {
                let type = cmark_node_get_type(node)
                if type == CMARK_NODE_IMAGE || type == CMARK_NODE_LINK { nodes.append(node) }
            }
        }
    }

    private static func safeLink(_ target: String) -> Bool {
        guard let url = URLComponents(string: target), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "mailto" { return !url.path.isEmpty }
        return (scheme == "https" || scheme == "http") && url.host?.isEmpty == false &&
            url.user == nil && url.password == nil
    }

    private static func html(_ content: String, theme: MarkdownPDFTheme) -> String {
        let style = theme.typography
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme:light; font-family:\(style.body); font-size:11pt; line-height:1.55; color:#20242b; }
        body { margin:0; overflow-wrap:anywhere; }
        @media screen { body { padding:24px 28px; } }
        @media print { * { -webkit-print-color-adjust:exact; print-color-adjust:exact; } }
        h1,h2,h3,h4,h5,h6 { font-family:\(style.headings); color:\(style.accent); line-height:1.2; margin:1.3em 0 .48em; break-after:avoid; }
        h1:first-child,h2:first-child { margin-top:0; }
        h1 { font-size:24pt; }
        h2 { font-size:18pt; }
        h3 { font-size:14pt; }
        p,ul,ol,blockquote,pre,table { margin:.65em 0 .86em; }
        p { orphans:3; widows:3; }
        a { color:\(style.accent); text-decoration:underline; }
        blockquote { border-left:.22em solid #acb4bf; padding:.05em .9em; color:#465263; }
        code { font-family:Menlo,monospace; font-size:.9em; overflow-wrap:anywhere; background:#f0f2f5; }
        pre { padding:.8em; background:#f0f2f5; border-radius:.25em; white-space:pre-wrap; overflow-wrap:anywhere; word-break:break-all; tab-size:4; }
        pre code { white-space:inherit; background:transparent; }
        img { max-width:100%; max-height:600pt; object-fit:contain; break-inside:avoid; }
        li { margin:.22em 0; }
        table { border-collapse:collapse; table-layout:fixed; width:100%; }
        tr { break-inside:avoid; }
        th,td { border:1px solid #cfd5dc; padding:.35em .55em; }
        th { background:#eef1f5; }
        hr { border:0; border-top:1px solid #c4ccd6; margin:1.5em 0; }
        </style></head><body>\(content)</body></html>
        """
    }
}
