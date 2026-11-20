import Foundation

public enum OfficeCalcOrientation: String, CaseIterable, Identifiable, Sendable {
    case saved = "Workbook"
    case portrait = "Portrait"
    case landscape = "Landscape"

    public var id: Self { self }
}

public struct OfficeCalcPrintOptions: Equatable, Sendable {
    public var sheetRange = ""
    public var cellRange = ""
    public var paper: PDFPrintPaper?
    public var orientation = OfficeCalcOrientation.saved
    public var fitsOnePageWide = false

    public init() {}

    var requiresPreparation: Bool {
        !sheetRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !cellRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || paper != nil || orientation != .saved || fitsOnePageWide
    }
}

enum OfficeCalcPreparation {
    static let flatFilter = "OpenDocument Spreadsheet Flat XML"

    static func prepare(
        _ input: URL, options: OfficeCalcPrintOptions, executable: URL, in staging: URL
    ) async throws -> URL {
        let flat = try await LibreOfficeHeadless.convert(input, filter: "fods:" + flatFilter,
                                                          fileExtension: "fods", executable: executable, in: staging)
        let bytes = try flat.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...64 * 1024 * 1024).contains(bytes) else {
            throw ToolError.invalid("Custom print settings require a readable workbook with up to 64 MB of print-preparation data.")
        }
        let document = try XMLDocument(contentsOf: flat, options: [.nodeLoadExternalEntitiesNever])
        let sheets = try elements(in: document, xpath: "/office:document/office:body/office:spreadsheet/table:table")
        guard !sheets.isEmpty else { throw ToolError.invalid("No worksheets were found.") }
        let selected = try Set(PageSelection.indices(options.sheetRange, pageCount: sheets.count))
        let range = try cellRange(options.cellRange)
        if range != nil, selected.count != 1 {
            throw ToolError.invalid("Choose one sheet to print a cell range.")
        }
        let filtersSheets = selected.count != sheets.count
        for (index, sheet) in sheets.enumerated() {
            try Task.checkCancellation()
            if !selected.contains(index) {
                sheet.removeAttribute(forName: "table:print-ranges")
                set("table:print", to: "false", on: sheet)
            } else if let range {
                guard let name = sheet.attribute(forName: "table:name")?.stringValue else {
                    throw ToolError.invalid("The selected worksheet has no name.")
                }
                let reference = "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
                set("table:print-ranges", to: "$" + reference + "." + range, on: sheet)
                sheet.removeAttribute(forName: "table:print")
            } else if filtersSheets && sheet.attribute(forName: "table:print-ranges") == nil {
                sheet.removeAttribute(forName: "table:print")
            }
        }
        let adjustsLayout = options.paper != nil || options.orientation != .saved || options.fitsOnePageWide
        if adjustsLayout {
            let layouts = try elements(in: document, xpath: "//style:page-layout/style:page-layout-properties")
            guard !layouts.isEmpty else { throw ToolError.invalid("LibreOffice did not expose the workbook’s page layout.") }
            for layout in layouts {
                try Task.checkCancellation()
                apply(options, to: layout)
            }
        }
        let output = flat.deletingLastPathComponent().appending(path: "Print selection.fods")
        try Task.checkCancellation()
        try document.xmlData(options: []).write(to: output, options: .atomic)
        return output
    }

    private static func elements(in document: XMLDocument, xpath: String) throws -> [XMLElement] {
        try document.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
    }

    private static func cellRange(_ input: String) throws -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.utf8.count <= 26 else { throw ToolError.invalid("Enter a cell range such as A1:F20.") }
        let pattern = /^\$?([A-Za-z]{1,3})\$?([1-9][0-9]{0,6})(?::\$?([A-Za-z]{1,3})\$?([1-9][0-9]{0,6}))?$/
        guard let match = text.wholeMatch(of: pattern),
              let start = cell(column: match.1, row: match.2),
              let end = cell(column: match.3 ?? match.1, row: match.4 ?? match.2),
              end.column >= start.column, end.row >= start.row else {
            throw ToolError.invalid("Enter an Excel cell range such as A1:F20.")
        }
        let firstColumn = match.1.uppercased()
        let lastColumn = (match.3 ?? match.1).uppercased()
        let lastRow = match.4 ?? match.2
        return "$\(firstColumn)$\(match.2):.$\(lastColumn)$\(lastRow)"
    }

    private static func cell(column: Substring, row: Substring) -> (column: Int, row: Int)? {
        let columnNumber = column.uppercased().utf8.reduce(0) { $0 * 26 + Int($1) - Int(UInt8(ascii: "A")) + 1 }
        guard columnNumber <= 16_384, let rowNumber = Int(row), rowNumber <= 1_048_576 else { return nil }
        return (columnNumber, rowNumber)
    }

    private static func apply(_ options: OfficeCalcPrintOptions, to layout: XMLElement) {
        if options.paper != nil || options.orientation != .saved {
            let savedLandscape = layout.attribute(forName: "style:print-orientation")?.stringValue == "landscape"
            let landscape = options.orientation == .saved ? savedLandscape : options.orientation == .landscape
            let savedWidth = layout.attribute(forName: "fo:page-width")?.stringValue
            let savedHeight = layout.attribute(forName: "fo:page-height")?.stringValue
            let portraitWidth: String
            let portraitHeight: String
            if let paper = options.paper {
                portraitWidth = "\(paper.size.width)pt"
                portraitHeight = "\(paper.size.height)pt"
            } else {
                portraitWidth = (savedLandscape ? savedHeight : savedWidth) ?? "210mm"
                portraitHeight = (savedLandscape ? savedWidth : savedHeight) ?? "297mm"
            }
            set("fo:page-width", to: landscape ? portraitHeight : portraitWidth, on: layout)
            set("fo:page-height", to: landscape ? portraitWidth : portraitHeight, on: layout)
            set("style:print-orientation", to: landscape ? "landscape" : "portrait", on: layout)
        }
        if options.fitsOnePageWide {
            layout.removeAttribute(forName: "style:scale-to")
            layout.removeAttribute(forName: "style:scale-to-pages")
            set("style:scale-to-X", to: "1", on: layout)
            set("style:scale-to-Y", to: "0", on: layout)
        }
    }

    private static func set(_ name: String, to value: String, on element: XMLElement) {
        element.removeAttribute(forName: name)
        let node = XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
        element.addAttribute(node)
    }
}
