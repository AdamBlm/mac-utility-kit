import Foundation
import cmark_gfm

enum MarkdownHeadingAnchors {
    static func assign(in document: UnsafeMutablePointer<cmark_node>) throws -> Set<String> {
        guard let iterator = cmark_iter_new(document) else { return [] }
        defer { cmark_iter_free(iterator) }
        var headings: [UnsafeMutablePointer<cmark_node>] = []
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            if event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator),
               cmark_node_get_type(node) == CMARK_NODE_HEADING {
                headings.append(node)
            }
        }
        var used = Set<String>()
        var nextSuffix: [String: Int] = [:]
        for heading in headings {
            try Task.checkCancellation()
            let base = slug(plainText(heading))
            var id = base
            var suffix = nextSuffix[base, default: 0]
            while !used.insert(id).inserted {
                suffix += 1
                id = "\(base)-\(suffix)"
            }
            nextSuffix[base] = suffix
            try apply(id, to: heading)
        }
        return used
    }

    // WebKit's PDF printer emits a URL action for non-ASCII fragments.
    // An ASCII alias at the same heading lets it emit an internal destination.
    static func printableID(_ id: String) -> String {
        if id.unicodeScalars.allSatisfy(\.isASCII) { return id }
        let encoded = id.utf8.map { String(format: "%02x", $0) }.joined()
        return "muk:heading:" + encoded
    }

    private static func plainText(_ heading: UnsafeMutablePointer<cmark_node>) -> String {
        guard let iterator = cmark_iter_new(heading) else { return "" }
        defer { cmark_iter_free(iterator) }
        var text = ""
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { return text }
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            switch cmark_node_get_type(node) {
            case CMARK_NODE_TEXT, CMARK_NODE_CODE:
                if let literal = cmark_node_get_literal(node) { text += String(cString: literal) }
            case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK:
                text.append(" ")
            default: break
            }
        }
    }

    private static func slug(_ heading: String) -> String {
        var result = ""
        for scalar in heading.lowercased().precomposedStringWithCanonicalMapping.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result.append("-")
            } else if scalar == "-" || scalar == "_" || CharacterSet.letters.contains(scalar)
                        || CharacterSet.decimalDigits.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? "section" : result
    }

    private static func apply(_ id: String, to heading: UnsafeMutablePointer<cmark_node>) throws {
        guard let wrapper = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else {
            throw ToolError.invalid("Could not prepare Markdown heading links.")
        }
        let level = cmark_node_get_heading_level(heading)
        let printable = printableID(id)
        let alias = printable == id ? "" : "<span id=\"\(printable)\"></span>"
        guard cmark_node_set_on_enter(wrapper, "<h\(level) id=\"\(id)\">" + alias) == 1,
              cmark_node_set_on_exit(wrapper, "</h\(level)>") == 1,
              cmark_node_replace(heading, wrapper) == 1 else {
            cmark_node_free(wrapper)
            throw ToolError.invalid("Could not prepare Markdown heading links.")
        }
        defer { cmark_node_free(heading) }
        while let child = cmark_node_first_child(heading) {
            guard cmark_node_append_child(wrapper, child) == 1 else {
                throw ToolError.invalid("Could not prepare Markdown heading links.")
            }
        }
    }
}
