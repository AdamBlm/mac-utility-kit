import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import UtilityCore

struct PDFToWordTests {
    @Test func flowingRecognizesNativeHeadingsListsAndScanTextWithLibreOffice() async throws {
        guard let engine = ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] else { return }
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = stage.appending(path: "input.pdf")
        try fixture(source)
        var options = PDFToWordOptions()
        options.libreOfficeExecutable = URL(filePath: engine)
        options.pages = "2–3"
        options.recognizeScans = false
        let embedded = try await PDFToWord.preview(source, options: options)
        #expect(embedded.pages.map(\.id) == [2, 3])
        #expect(embedded.pages[1].text.isEmpty)

        options.recognizeScans = true
        let preview = try await PDFToWord.preview(source, options: options)
        #expect(preview.pages[1].usedOCR)
        #expect(preview.pages[1].text.contains("Invoice number 7429"))
        var workflow = ToolOptions()
        workflow.pdfToWord = options
        let job = try await ToolRunner.run(.pdfToWord, inputs: [source], destination: stage, imageSize: 0,
                                           options: workflow) { _ in }
        #expect(job.failures.isEmpty)
        let output = try #require(job.outputs.first)
        #expect(output.pathExtension == "docx")
        let document = try await body(output, in: stage)
        let text = try textContent(document)
        #expect(text.contains("Project Overview"))
        #expect(text.contains("Invoice number 7429"))
        #expect(!text.contains("Excluded first page"))
        #expect(try document.nodes(forXPath: "//w:pStyle[@w:val='Heading1']").count == 1)
        #expect(try !document.nodes(forXPath: "//w:numPr").isEmpty)

        let executable = URL(filePath: "/opt/homebrew/bin/pandoc")
        if FileManager.default.isExecutableFile(atPath: executable.path) {
            let plain = stage.appending(path: "reader.txt")
            try await DocumentConversionEngines.pandoc(output, from: .format(.docx), to: plain,
                                                         target: .plain, executable: executable)
            #expect(try String(contentsOf: plain, encoding: .utf8).contains("Invoice number 7429"))
        }
    }

    @Test func layoutRetainsEditableNativeAndOCRTextPlusFiguresWithLibreOffice() async throws {
        guard let engine = ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] else { return }
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = stage.appending(path: "input.pdf")
        try fixture(source)
        var options = PDFToWordOptions()
        options.mode = .layout
        options.pages = "2, 3"
        options.libreOfficeExecutable = URL(filePath: engine)
        let output = stage.appending(path: "layout.docx")
        _ = try await PDFToWord.export(source, to: output, options: options) { _ in }
        let document = try await body(output, in: stage)
        let text = try textContent(document)
        #expect(text.contains("Project Overview"))
        #expect(text.contains("Invoice number 7429"))
        #expect(!text.contains("Excluded first page"))
        #expect(try !document.nodes(forXPath: "//w:drawing").isEmpty)
        let reopened = try await LibreOfficeHeadless.convert(output, filter: "pdf:writer_pdf_Export",
                                                            fileExtension: "pdf", executable: URL(filePath: engine), in: stage)
        let rerendered = try #require(PDFDocument(url: reopened))
        #expect(rerendered.pageCount >= 2)
    }

    @Test func hybridPageKeepsNativeAndRasterTextInBothWordModes() async throws {
        guard let engine = ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] else { return }
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = stage.appending(path: "Hybrid.pdf")
        var media = CGRect(x: 0, y: 0, width: 500, height: 650)
        let pdf = try #require(CGContext(source as CFURL, mediaBox: &media, nil))
        let bitmap = try #require(CGContext(data: nil, width: 880, height: 160, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 880, height: 160))
        draw("Invoice body 7429", size: 52, x: 40, y: 76, to: bitmap)
        let raster = try #require(bitmap.makeImage())
        pdf.beginPDFPage(nil)
        draw("Project header", size: 27, x: 48, y: 575, to: pdf)
        pdf.draw(raster, in: CGRect(x: 44, y: 390, width: 440, height: 80))
        pdf.endPDFPage()
        pdf.closePDF()
        let original = try Data(contentsOf: source)

        var options = PDFToWordOptions()
        options.libreOfficeExecutable = URL(filePath: engine)
        options.recognizeScans = false
        let native = try await PDFToWord.preview(source, options: options)
        #expect(native.pages.first?.text == "Project header")
        options.recognizeScans = true
        for mode in [PDFToWordOptions.Mode.flowing, .layout] {
            options.mode = mode
            let preview = try await PDFToWord.preview(source, options: options)
            let page = try #require(preview.pages.first)
            #expect(page.usedOCR)
            for text in ["Project header", "Invoice body 7429"] {
                #expect(page.text.components(separatedBy: text).count == 2)
            }
            let output = stage.appending(path: mode.rawValue + ".docx")
            _ = try await PDFToWord.export(source, to: output, options: options) { _ in }
            let exported = try textContent(await body(output, in: stage))
            for text in ["Project header", "Invoice body 7429"] {
                #expect(exported.components(separatedBy: text).count == 2, "\(mode.rawValue): \(exported)")
            }
        }
        #expect(try Data(contentsOf: source) == original)

        let form = try #require(PDFDocument(url: source))
        let formPage = try #require(form.page(at: 0))
        let widget = PDFAnnotation(bounds: CGRect(x: 50, y: 300, width: 120, height: 24),
                                   forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "Reviewed by"
        formPage.addAnnotation(widget)
        let formURL = stage.appending(path: "Form.pdf")
        try #require(form.write(to: formURL))
        let preview = try await PDFToWord.preview(formURL, options: options)
        #expect(preview.pages.first?.usedOCR == false)
        #expect(preview.warnings.contains { $0.contains("interactive forms") })
        let output = stage.appending(path: "Form.docx")
        let summary = try await PDFToWord.export(formURL, to: output, options: options) { _ in }
        #expect(summary.contains("OCR skipped for interactive forms"))
        #expect(try textContent(await body(output, in: stage)).contains("Project header"))
    }

    @Test func missingEngineAndInvalidSelectionDoNotPublish() async throws {
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = stage.appending(path: "input.pdf")
        try fixture(source)
        let output = stage.appending(path: "miss.docx")
        var options = PDFToWordOptions()
        #expect(PDFToWord.optionIssue(source, options: options) != nil)
        await #expect(throws: ToolError.self) { _ = try await PDFToWord.export(source, to: output, options: options) { _ in } }
        options.pages = "99"
        await #expect(throws: ToolError.self) { _ = try await PDFToWord.preview(source, options: options) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private func makeStage() throws -> URL {
        let stage = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        return stage
    }

    private func body(_ url: URL, in stage: URL) async throws -> XMLDocument {
        let entries = try await ArchiveTools.list(url)
        let document = try #require(entries.first { $0.path == "word/document.xml" })
        let inspection = stage.appending(path: "Inspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: inspection, withIntermediateDirectories: false)
        _ = try await ArchiveTools.extract(url, to: inspection, selected: [document.id], conflicts: .skip)
        return try XMLDocument(contentsOf: inspection.appending(path: "word/document.xml"),
                               options: [.nodeLoadExternalEntitiesNever])
    }

    private func textContent(_ document: XMLDocument) throws -> String {
        try document.nodes(forXPath: "//w:t[not(ancestor::*[local-name() = 'Fallback'])]").compactMap(\.stringValue).joined(separator: " ")
    }

    private func fixture(_ url: URL) throws {
        var media = CGRect(x: 0, y: 0, width: 500, height: 650)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        pdf.beginPDFPage(nil)
        draw("Excluded first page", size: 16, x: 52, y: 520, to: pdf)
        pdf.endPDFPage()

        pdf.beginPDFPage(nil)
        draw("Project Overview", size: 29, x: 52, y: 585, to: pdf)
        draw("An editable document with body text.", size: 13, x: 52, y: 540, to: pdf)
        draw("• Test the first supported list item", size: 13, x: 52, y: 510, to: pdf)
        draw("• Test the second supported list item", size: 13, x: 52, y: 486, to: pdf)
        pdf.endPDFPage()

        let bitmap = try #require(CGContext(data: nil, width: 1000, height: 1300, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1000, height: 1300))
        draw("Invoice number 7429", size: 54, x: 105, y: 1040, to: bitmap)
        let raster = try #require(bitmap.makeImage())
        pdf.beginPDFPage(nil)
        pdf.draw(raster, in: media)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    private func draw(_ string: String, size: CGFloat, x: CGFloat, y: CGFloat, to canvas: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]))
        canvas.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, canvas)
    }
}
