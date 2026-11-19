import Foundation

enum OfficeWriterPreparation {
    static let flatFilter = "OpenDocument Text Flat XML"

    static func prepare(
        _ input: URL, paper: PDFPrintPaper, executable: URL, in staging: URL, inputFilter: String?
    ) async throws -> URL {
        let flat = try await LibreOfficeHeadless.convert(
            input, filter: "fodt:" + flatFilter, fileExtension: "fodt",
            executable: executable, in: staging, inputFilter: inputFilter
        )
        let bytes = try flat.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...64 * 1024 * 1024).contains(bytes) else {
            throw ToolError.invalid("Custom paper sizes require up to 64 MB of print-preparation data.")
        }
        let document = try XMLDocument(contentsOf: flat, options: [.nodeLoadExternalEntitiesNever])
        let layouts = try document.nodes(forXPath: "//style:page-layout/style:page-layout-properties")
            .compactMap { $0 as? XMLElement }
        guard !layouts.isEmpty else {
            throw ToolError.invalid("LibreOffice did not expose the document’s page layout.")
        }
        for layout in layouts {
            try Task.checkCancellation()
            let landscape = layout.attribute(forName: "style:print-orientation")?.stringValue == "landscape"
            let size = paper.size
            for (name, value) in [("fo:page-width", landscape ? size.height : size.width),
                                  ("fo:page-height", landscape ? size.width : size.height)] {
                let length = String(format: "%.2fpt", locale: Locale(identifier: "en_US_POSIX"), Double(value))
                if let attribute = layout.attribute(forName: name) {
                    attribute.stringValue = length
                } else if let attribute = XMLNode.attribute(withName: name, stringValue: length) as? XMLNode {
                    layout.addAttribute(attribute)
                }
            }
        }
        let output = flat.deletingLastPathComponent().appending(path: "Print layout.fodt")
        try Task.checkCancellation()
        try document.xmlData(options: []).write(to: output, options: .atomic)
        return output
    }
}
