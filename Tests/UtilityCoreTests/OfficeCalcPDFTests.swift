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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func repeatedPrintTitlesSurviveDefaultAndCustomXLSXPrintRanges() async throws {
        let executable = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"]))
        let staging = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        let title = "TITLE42"
        let rows = [title] + (1...240).map { "ROW\($0)" }
        let csv = staging.appending(path: "Rows.csv")
        try Data(rows.joined(separator: "\n").utf8).write(to: csv)
        let flat = try await LibreOfficeHeadless.convert(csv, filter: "fods:" + OfficeCalcPreparation.flatFilter,
                                                          fileExtension: "fods", executable: executable, in: staging)
        let xml = try XMLDocument(contentsOf: flat, options: [.nodeLoadExternalEntitiesNever])
        let sheet = try #require(xml.nodes(forXPath: "//office:spreadsheet/table:table").first as? XMLElement)
        let firstRow = try #require(sheet.nodes(forXPath: "table:table-row").first)
        let header = XMLElement(name: "table:table-header-rows")
        let rowIndex = firstRow.index
        firstRow.detach()
        header.addChild(firstRow)
        sheet.insertChild(header, at: rowIndex)
        let flatSource = staging.appending(path: "Print Titles.fods")
        try xml.xmlData(options: []).write(to: flatSource)
        let xlsx = try await LibreOfficeHeadless.convert(flatSource, filter: "xlsx:Calc MS Excel 2007 XML",
                                                          fileExtension: "xlsx", executable: executable,
                                                          in: staging, inputFilter: OfficeCalcPreparation.flatFilter)
        let original = try Data(contentsOf: xlsx)

        var options = OfficePDFOptions()
        options.libreOfficeExecutable = executable
        let defaultOutput = staging.appending(path: "Default.pdf")
        _ = try await OfficePDF.export(xlsx, to: defaultOutput, kind: .excel, options: options) { _ in }
        let defaultPDF = try #require(PDFDocument(url: defaultOutput))
        try verifyRepeatingTitle(title, in: defaultPDF)
        #expect(defaultPDF.string?.contains("ROW240") == true)

        options.spreadsheetPrint.cellRange = "A2:B200"
        let customOutput = staging.appending(path: "Custom.pdf")
        _ = try await OfficePDF.export(xlsx, to: customOutput, kind: .excel, options: options) { _ in }
        let customPDF = try #require(PDFDocument(url: customOutput))
        try verifyRepeatingTitle(title, in: customPDF)
        #expect(customPDF.string?.contains("ROW199") == true)
        #expect(customPDF.string?.contains("ROW240") == false)
        #expect(try Data(contentsOf: xlsx) == original)
    }

    private func verifyRepeatingTitle(_ title: String, in document: PDFDocument) throws {
        try #require(document.pageCount > 1)
        for index in 0..<document.pageCount {
            let text = try #require(document.page(at: index)?.string)
            #expect(text.contains(title), "Print title missing on page \(index + 1)")
        }
    }
}
