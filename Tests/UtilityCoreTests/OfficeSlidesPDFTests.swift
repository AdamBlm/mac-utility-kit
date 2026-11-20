import CoreText
import Foundation
import PDFKit
import Testing
@testable import UtilityCore

struct OfficeSlidesPDFTests {
    @Test func handoutPreviewListsSelectedSlidesOnEachPageInOrder() {
        let selected = [1, 3, 4, 7, 9]
        #expect(Array(OfficeSlideLayout.two.slideNumbers(in: selected, onHandoutPage: 1)) == [1, 3])
        #expect(Array(OfficeSlideLayout.two.slideNumbers(in: selected, onHandoutPage: 2)) == [4, 7])
        #expect(Array(OfficeSlideLayout.two.slideNumbers(in: selected, onHandoutPage: 3)) == [9])
        #expect(OfficeSlideLayout.two.slideNumbers(in: selected, onHandoutPage: 4).isEmpty)
    }

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
        #expect(Array(options.slideLayout.slideNumbers(in: layout.selectedPages, onHandoutPage: 1)) == [1, 2])
        let preview = try OfficePDF.renderedPage(layout, page: 1, handout: true)
        #expect(preview.size == CGSize(width: 612, height: 792))
        var toolOptions = ToolOptions()
        toolOptions.officePDF = options
        let report = try await ToolRunner.run(
            .powerPointToPDF, inputs: [source], destination: staging, imageSize: 0, options: toolOptions
        ) { _ in }
        #expect(report.failures.isEmpty)
        #expect(report.summaries.first?.contains("Animations, transitions, and audio or video playback are omitted.") == true)
        let output = try #require(report.outputs.first)
        let handout = try #require(PDFDocument(url: output))
        #expect(handout.pageCount == 1)
        let text = try #require(handout.page(at: 0)?.string)
        #expect(text.contains("FIRST TRACKABLE SLIDE") && text.contains("HIDDEN TRACKABLE SLIDE"))
        #expect(!text.contains("LAST TRACKABLE SLIDE"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func missingFontFallsBackToSearchableSlidesInPreviewAndExport() async throws {
        let executable = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"]))
        let staging = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        let missingFont = "Mac Utility Kit Fixture Absent 7F4682"
        let availableFonts = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        try #require(!availableFonts.contains(missingFont))
        let source = try await deck(in: staging, executable: executable, missingFont: missingFont)
        let original = try Data(contentsOf: source)
        let entries = try await ArchiveTools.list(source)
        let slidePath = "ppt/slides/slide1.xml"
        let content = try #require(entries.first { $0.path == slidePath })
        let expanded = staging.appending(path: "Expanded", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false)
        _ = try await ArchiveTools.extract(source, to: expanded, selected: [content.id], conflicts: .skip)
        let xml = try String(contentsOf: expanded.appending(path: slidePath), encoding: .utf8)
        try #require(xml.contains(missingFont))

        var options = OfficePDFOptions()
        options.libreOfficeExecutable = executable
        for includesHidden in [false, true] {
            options.includesHiddenSlides = includesHidden
            let expected = includesHidden
                ? ["FIRST TRACKABLE SLIDE", "HIDDEN TRACKABLE SLIDE", "LAST TRACKABLE SLIDE"]
                : ["FIRST TRACKABLE SLIDE", "LAST TRACKABLE SLIDE"]
            let preview = try await OfficePDF.preview(source, kind: .powerPoint, options: options)
            let previewPDF = try #require(PDFDocument(data: preview.pdf))
            try verifySearchableSlides(expected, in: previewPDF)
            let output = staging.appending(path: includesHidden ? "All slides.pdf" : "Visible slides.pdf")
            _ = try await OfficePDF.export(source, to: output, kind: .powerPoint, options: options) { _ in }
            let exportedPDF = try #require(PDFDocument(url: output))
            try verifySearchableSlides(expected, in: exportedPDF)
        }
        #expect(try Data(contentsOf: source) == original)
    }

    private func verifySearchableSlides(_ expected: [String], in document: PDFDocument) throws {
        try #require(document.pageCount == expected.count)
        for (index, marker) in expected.enumerated() {
            #expect(document.page(at: index)?.string?.contains(marker) == true)
            #expect(!document.findString(marker, withOptions: .caseInsensitive).isEmpty)
        }
        if expected.count == 2 {
            #expect(document.findString("HIDDEN TRACKABLE SLIDE", withOptions: .caseInsensitive).isEmpty)
        }
    }

    private func deck(in staging: URL, executable: URL, missingFont: String? = nil) async throws -> URL {
        let presentation = staging.appending(path: "Source.fodp")
        let fontStyle = missingFont.map {
            """
            <style:style style:name="FixtureText" style:family="text">
              <style:text-properties fo:font-family="\($0)" fo:font-size="20pt"/>
            </style:style>
            """
        } ?? ""
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
          \(fontStyle)
          <style:page-layout style:name="pageLayout"><style:page-layout-properties fo:page-width="28cm" fo:page-height="15cm" style:print-orientation="landscape"/></style:page-layout>
          <style:style style:name="visible" style:family="drawing-page"><style:drawing-page-properties presentation:visibility="visible"/></style:style>
          <style:style style:name="hidden" style:family="drawing-page"><style:drawing-page-properties presentation:visibility="hidden"/></style:style>
        </office:automatic-styles>
        <office:master-styles><style:master-page style:name="Default" style:page-layout-name="pageLayout"/></office:master-styles>
        <office:body><office:presentation>
        """
        let content = [("FIRST", false), ("HIDDEN", true), ("LAST", false)].map { title, hidden in
            let marker = "\(title) TRACKABLE SLIDE"
            let text = missingFont == nil ? marker : "<text:span text:style-name=\"FixtureText\">\(marker)</text:span>"
            return """
            <draw:page draw:name="\(title)" draw:style-name="\(hidden ? "hidden" : "visible")" draw:master-page-name="Default">
              <draw:frame svg:x="1cm" svg:y="1cm" svg:width="20cm" svg:height="3cm"><draw:text-box>
                <text:p>\(text)</text:p>
              </draw:text-box></draw:frame>
            </draw:page>
            """
        }.joined(separator: "\n")
        try Data((prefix + content + "</office:presentation></office:body></office:document>").utf8).write(to: presentation)
        if missingFont != nil {
            return try await LibreOfficeHeadless.convert(presentation, filter: "pptx:Impress MS PowerPoint 2007 XML",
                                                          fileExtension: "pptx", executable: executable, in: staging)
        }
        return try await LibreOfficeHeadless.convert(presentation, filter: "odp:impress8", fileExtension: "odp",
                                                      executable: executable, in: staging)
    }
}
