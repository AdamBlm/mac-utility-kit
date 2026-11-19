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

        let original = try Data(contentsOf: docx)
        options.wordPaper = .a4
        let reflowed = try await OfficePDF.preview(docx, kind: .word, options: options)
        #expect(reflowed.selectedPages == [2])
        let paper = try OfficePDF.renderedPage(reflowed, page: 2).size
        #expect(abs(paper.width - 595.28) < 1 && abs(paper.height - 841.89) < 1)

        let destination = folder.appending(path: "Selected.pdf")
        _ = try await OfficePDF.export(docx, to: destination, kind: .word, options: options) { _ in }
        let output = try #require(PDFDocument(url: destination))
        #expect(output.pageCount == 1)
        let page = try #require(output.page(at: 0))
        #expect(page.bounds(for: .cropBox).size == paper)
        #expect(try Data(contentsOf: docx) == original)
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func selectsPagesAfterPaperSizeReflowsTheDocument() async throws {
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Reflow.rtf")
        let header = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\paperw12240\paperh15840\margl1440\margr1440\margt1440\margb1440\pard\f0\fs24\sl400\slmult0 "#
        let lines = (1...39).map { "Line \($0)" }.joined(separator: #"\par "#)
        try Data((header + lines + "}").utf8).write(to: source)

        var options = OfficePDFOptions()
        options.libreOfficeExecutable = try Self.executable()
        options.pageRange = "2"
        let original = try await OfficePDF.preview(source, kind: .word, options: options)
        #expect(original.totalPages == 2)
        #expect(original.selectedPages == [2])

        options.wordPaper = .legal
        let destination = folder.appending(path: "Reflowed.pdf")
        await #expect(throws: ToolError.self) {
            try await OfficePDF.export(source, to: destination, kind: .word, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        options.pageRange = "1"
        let reflowed = try await OfficePDF.preview(source, kind: .word, options: options)
        #expect(reflowed.totalPages == 1)
        let pdf = try #require(PDFDocument(data: reflowed.pdf))
        #expect(pdf.page(at: 0)?.string?.contains("Line 39") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func paperOverridePreservesEachSectionOrientation() async throws {
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Mixed.rtf")
        let rtf = #"""
        {\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}
        \paperw11906\paperh16838\margl1440\margr1440\margt1440\margb1440
        \sectd\pgwsxn11906\pghsxn16838\pard\f0\fs28 FIRST PORTRAIT\par
        \sect\sectd\lndscpsxn\pgwsxn16838\pghsxn11906\pard\f0\fs28 SECOND LANDSCAPE\par}
        """#
        try Data(rtf.utf8).write(to: source)
        var options = OfficePDFOptions()
        options.libreOfficeExecutable = try Self.executable()
        options.wordPaper = .letter

        let preview = try await OfficePDF.preview(source, kind: .word, options: options)
        #expect(preview.totalPages == 2)
        let portrait = try OfficePDF.renderedPage(preview, page: 1).size
        let landscape = try OfficePDF.renderedPage(preview, page: 2).size
        #expect(abs(portrait.width - 612) < 1 && abs(portrait.height - 792) < 1)
        #expect(abs(landscape.width - 792) < 1 && abs(landscape.height - 612) < 1)

        options.pageRange = "2"
        let destination = folder.appending(path: "Landscape.pdf")
        _ = try await OfficePDF.export(source, to: destination, kind: .word, options: options) { _ in }
        let document = try #require(PDFDocument(url: destination))
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        #expect(page.bounds(for: .cropBox).size == landscape)
        #expect(page.string?.contains("SECOND LANDSCAPE") == true)
    }

    @Test func rejectsNonFilesAndOversizedDocumentsBeforeConversion() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appending(path: "Directory.docx", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let oversized = folder.appending(path: "Oversized.docx")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
        try handle.close()

        var options = OfficePDFOptions()
        options.libreOfficeExecutable = folder
        #expect(OfficePDF.optionIssue(oversized, kind: .word, options: options)
                == "Choose LibreOffice or its soffice executable.")
        options.libreOfficeExecutable = URL(fileURLWithPath: "/usr/bin/true")
        for input in [directory, oversized] {
            let expected = "Choose a readable document up to 256 MB."
            #expect(OfficePDF.optionIssue(input, kind: .word, options: options) == expected)
            let error = await #expect(throws: ToolError.self) {
                try await OfficePDF.preview(input, kind: .word, options: options)
            }
            #expect(error?.localizedDescription == expected)
        }
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
