import Foundation
import PDFKit
import Testing
@testable import UtilityCore

struct OfficeCalcPDFTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func selectedSheetPrintRangePaperAndFitReachCalc() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"])
        let executable = URL(filePath: path)
        let staging = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        let csv = staging.appending(path: "Seed.csv")
        var cells = Array(repeating: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", count: 18)
        cells[0] = "Start marker"
        cells[17] = "Right edge marker"
        try Data(cells.joined(separator: ",").utf8).write(to: csv)
        let ods = try await LibreOfficeHeadless.convert(csv, filter: "ods:calc8", fileExtension: "ods",
                                                         executable: executable, in: staging)
        let flat = try await LibreOfficeHeadless.convert(ods, filter: "fods:" + OfficeCalcPreparation.flatFilter,
                                                          fileExtension: "fods", executable: executable, in: staging)
        let xml = try XMLDocument(contentsOf: flat, options: [.nodeLoadExternalEntitiesNever])
        let first = try #require(xml.nodes(forXPath: "//office:spreadsheet/table:table").first as? XMLElement)
        let second = try #require(first.copy() as? XMLElement)
        second.attribute(forName: "table:name")?.stringValue = "Finance's May"
        let firstCell = try #require(first.nodes(forXPath: "table:table-row/table:table-cell/text:p").first)
        firstCell.stringValue = "Omitted marker"
        let container = try #require(first.parent as? XMLElement)
        container.addChild(second)
        let source = staging.appending(path: "Workbook.fods")
        try xml.xmlData(options: []).write(to: source)
        let xlsx = try await LibreOfficeHeadless.convert(source, filter: "xlsx:Calc MS Excel 2007 XML",
                                                          fileExtension: "xlsx", executable: executable,
                                                          in: staging, inputFilter: OfficeCalcPreparation.flatFilter)
        let original = try Data(contentsOf: xlsx)

        var options = OfficeCalcPrintOptions()
        options.sheetRange = "2"
        options.cellRange = "A1:R1"
        options.fitsOnePageWide = true
        options.paper = .letter
        options.orientation = .landscape
        var office = OfficePDFOptions()
        office.libreOfficeExecutable = executable
        office.spreadsheetPrint = options
        let preview = try await OfficePDF.preview(xlsx, kind: .excel, options: office)
        #expect(preview.totalPages == 1)
        var toolOptions = ToolOptions()
        toolOptions.officePDF = office
        let report = try await ToolRunner.run(
            .excelToPDF, inputs: [xlsx], destination: staging, imageSize: 0, options: toolOptions
        ) { _ in }
        #expect(report.failures.isEmpty)
        let pdf = try #require(report.outputs.first)
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        #expect(page.string?.contains("Start marker") == true)
        #expect(page.string?.contains("Right edge marker") == true)
        #expect(page.string?.contains("Omitted marker") == false)
        #expect(abs(page.bounds(for: .mediaBox).width - 792) < 1)
        #expect(abs(page.bounds(for: .mediaBox).height - 612) < 1)
        #expect(try Data(contentsOf: xlsx) == original)

        options.cellRange = "A1:A1"
        office.spreadsheetPrint = options
        let clippedPDF = staging.appending(path: "Cell selection.pdf")
        _ = try await OfficePDF.export(xlsx, to: clippedPDF, kind: .excel, options: office) { _ in }
        let clippedDocument = try #require(PDFDocument(url: clippedPDF))
        #expect(clippedDocument.string?.contains("Start marker") == true)
        #expect(clippedDocument.string?.contains("Right edge marker") == false)

        office.singlePageSheets = true
        office.pageRange = "2"
        let wholeSheetPDF = staging.appending(path: "Second sheet.pdf")
        _ = try await OfficePDF.export(xlsx, to: wholeSheetPDF, kind: .excel, options: office) { _ in }
        let wholeSheet = try #require(PDFDocument(url: wholeSheetPDF))
        #expect(wholeSheet.pageCount == 1)
        #expect(wholeSheet.string?.contains("Right edge marker") == true)
        #expect(wholeSheet.string?.contains("Omitted marker") == false)
    }
}
