import Foundation
import PDFKit
import Testing
@testable import UtilityCore

struct OfficeSlidesPDFTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func hiddenSlidesRangeAndVectorHandoutMatchRenderedSequence() async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let engine = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"]))
        let source = try await deck(in: staging, executable: engine)
        var options = OfficePDFOptions()
        options.libreOfficeExecutable = engine
        let visible = try await OfficePDF.preview(source, kind: .powerPoint, options: options)
        #expect(visible.totalPages == 2)
        let visiblePDF = try #require(PDFDocument(data: visible.pdf))
        #expect(visiblePDF.page(at: 0)?.string?.contains("FIRST TRACKABLE SLIDE") == true)
        #expect(visiblePDF.page(at: 1)?.string?.contains("LAST TRACKABLE SLIDE") == true)

        options.pageRange = "2"
        let visibleRange = staging.appending(path: "Visible range.pdf")
        _ = try await OfficePDF.export(source, to: visibleRange, kind: .powerPoint, options: options) { _ in }
        let visiblePage = try #require(PDFDocument(url: visibleRange))
        #expect(visiblePage.pageCount == 1)
        #expect(visiblePage.page(at: 0)?.string?.contains("LAST TRACKABLE SLIDE") == true)

        options.includesHiddenSlides = true
        let included = staging.appending(path: "Selected hidden.pdf")
        _ = try await OfficePDF.export(source, to: included, kind: .powerPoint, options: options) { _ in }
        let hiddenPage = try #require(PDFDocument(url: included))
        #expect(hiddenPage.pageCount == 1)
        #expect(hiddenPage.page(at: 0)?.string?.contains("HIDDEN TRACKABLE SLIDE") == true)

        options.pageRange = "1–2"
        options.slideLayout = .two
        options.handoutPaper = .letter
        let layout = try await OfficePDF.preview(source, kind: .powerPoint, options: options)
        #expect(layout.totalPages == 3 && layout.handoutPages == 1)
        let preview = try OfficePDF.renderedPage(layout, page: 1, handout: true)
        #expect(preview.size == CGSize(width: 612, height: 792))
        var toolOptions = ToolOptions()
        toolOptions.officePDF = options
        let report = try await ToolRunner.run(
            .powerPointToPDF, inputs: [source], destination: staging, imageSize: 0, options: toolOptions
        ) { _ in }
        #expect(report.failures.isEmpty)
        let output = try #require(report.outputs.first)
        let handout = try #require(PDFDocument(url: output))
        #expect(handout.pageCount == 1)
        let text = try #require(handout.page(at: 0)?.string)
        #expect(text.contains("FIRST TRACKABLE SLIDE") && text.contains("HIDDEN TRACKABLE SLIDE"))
        #expect(!text.contains("LAST TRACKABLE SLIDE"))
    }

    private func deck(in staging: URL, executable: URL) async throws -> URL {
        let presentation = staging.appending(path: "Source.fodp")
        let prefix = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
          xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
          xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
          xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
          office:mimetype="application/vnd.oasis.opendocument.presentation" office:version="1.3">
        <office:automatic-styles>
          <style:page-layout style:name="pageLayout"><style:page-layout-properties fo:page-width="28cm" fo:page-height="15cm" style:print-orientation="landscape"/></style:page-layout>
          <style:style style:name="visible" style:family="drawing-page"><style:drawing-page-properties presentation:visibility="visible"/></style:style>
          <style:style style:name="hidden" style:family="drawing-page"><style:drawing-page-properties presentation:visibility="hidden"/></style:style>
        </office:automatic-styles>
        <office:master-styles><style:master-page style:name="Default" style:page-layout-name="pageLayout"/></office:master-styles>
        <office:body><office:presentation>
        """
        let content = [("FIRST", false), ("HIDDEN", true), ("LAST", false)].map { title, hidden in
            """
            <draw:page draw:name="\(title)" draw:style-name="\(hidden ? "hidden" : "visible")" draw:master-page-name="Default">
              <draw:frame svg:x="1cm" svg:y="1cm" svg:width="20cm" svg:height="3cm"><draw:text-box>
                <text:p>\(title) TRACKABLE SLIDE</text:p>
              </draw:text-box></draw:frame>
            </draw:page>
            """
        }.joined(separator: "\n")
        try Data((prefix + content + "</office:presentation></office:body></office:document>").utf8).write(to: presentation)
        return try await LibreOfficeHeadless.convert(presentation, filter: "odp:impress8", fileExtension: "odp",
                                                      executable: executable, in: staging)
    }
}
