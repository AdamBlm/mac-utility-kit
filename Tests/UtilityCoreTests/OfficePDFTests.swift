import Foundation
import PDFKit
import Testing
import UtilityCore

struct OfficePDFTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func wordPreviewUsesActualPageBreaksAndSelectedPDFRetainsUnicodeAndLinks() async throws {
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Source.rtf")
        let rtf = #"""
        {\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0 Helvetica;}}
        \paperw12240\paperh15840\margl1440\margr1440\margt1440\margb1440
        \pard\f0\fs28 FIRST PAGE\par
        \page\pard SECOND PAGE Caf\u233? \u26481?\u20140?\par
        {\field{\*\fldinst HYPERLINK "https://example.test/source"}{\fldrslt {\ul Read the guide}}}\par
        }
        """#
        try Data(rtf.utf8).write(to: source)
        var options = OfficePDFOptions()
        options.libreOfficeExecutable = try Self.executable()
        options.pageRange = "2"

        let docx = folder.appending(path: "Source.docx")
        var conversion = DocumentConvertOptions()
        conversion.libreOfficeExecutable = options.libreOfficeExecutable
        conversion.prefersLibreOffice = true
        conversion.target = .docx
        _ = try await DocumentConvert.export(source, to: docx, options: conversion) { _ in }

        let preview = try await OfficePDF.preview(docx, kind: .word, options: options)
        #expect(preview.totalPages == 2)
        #expect(preview.selectedPages == [2])
        let actual = try OfficePDF.renderedPage(preview, page: 2)
        #expect(abs(actual.size.width - 612) < 1 && abs(actual.size.height - 792) < 1)
        let fullPDF = try #require(PDFDocument(data: preview.pdf))
        #expect(fullPDF.page(at: 0)?.string?.contains("FIRST PAGE") == true)

        let destination = folder.appending(path: "Selected.pdf")
        _ = try await OfficePDF.export(docx, to: destination, kind: .word, options: options) { _ in }
        let output = try #require(PDFDocument(url: destination))
        #expect(output.pageCount == 1)
        let page = try #require(output.page(at: 0))
        let text = try #require(page.string)
        #expect(text.contains("SECOND PAGE Café 東京"))
        #expect(!text.contains("FIRST PAGE"))
        #expect(page.annotations.contains {
            ($0.url ?? ($0.action as? PDFActionURL)?.url)?.absoluteString == "https://example.test/source"
        })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func wordReadsUTF16TextAndRejectsOutOfRangePagesWithoutPublishing() async throws {
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "Unicode.txt")
        let output = folder.appending(path: "Unicode.pdf")
        try #require("Bonjour café, Ελληνικά".data(using: .utf16)).write(to: input)
        var options = OfficePDFOptions()
        options.libreOfficeExecutable = try Self.executable()
        options.pageRange = "1"
        _ = try await OfficePDF.export(input, to: output, kind: .word, options: options) { _ in }
        let document = try #require(PDFDocument(url: output))
        #expect(document.page(at: 0)?.string?.contains("Bonjour café, Ελληνικά") == true)
        options.pageRange = "99"
        let missing = folder.appending(path: "Missing.pdf")
        await #expect(throws: ToolError.self) {
            try await OfficePDF.export(input, to: missing, kind: .word, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func reportsUnsupportedInputAndMissingEngine() {
        #expect(OfficePDF.optionIssue(URL(fileURLWithPath: "/tmp/test.xlsx"), kind: .word, options: .init())?.contains("unsupported") == true)
        #expect(OfficePDF.optionIssue(URL(fileURLWithPath: "/tmp/test.docx"), kind: .word, options: .init())?.contains("LibreOffice") == true)
    }

    private static func executable() throws -> URL {
        URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"]))
    }

    private static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }
}
