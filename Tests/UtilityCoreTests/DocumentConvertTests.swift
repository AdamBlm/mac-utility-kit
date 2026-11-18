import Foundation
import Testing
import UtilityCore

struct DocumentConvertTests {
    @Test func nativePlainTextPreservesUnicodeAndEscapesMarkup() async throws {
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "Literal.txt")
        let literal = "Café et 東京\n# literal heading\n````\n<tests>&"
        try #require(literal.data(using: .utf16)).write(to: input)
        var options = DocumentConvertOptions()
        options.target = .markdown
        let markdown = folder.appending(path: "Output.md")
        _ = try await DocumentConvert.export(input, to: markdown, options: options) { _ in }
        let code = try String(contentsOf: markdown, encoding: .utf8)
        #expect(code.hasPrefix("`````\n") && code.contains(literal))

        options.target = .html
        let html = folder.appending(path: "Output.html")
        let summary = try await DocumentConvert.export(input, to: html, options: options) { _ in }
        let markup = try String(contentsOf: html, encoding: .utf8)
        #expect(markup.contains("Café et 東京"))
        #expect(markup.contains("&lt;tests&gt;&amp;"))
        #expect(!markup.contains("<tests>"))
        #expect(summary.contains("macOS"))
    }

    @Test func runnerPreservesEarlierOutputWhenFilenameTemplateCollides() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "First.txt")
        let second = directory.appending(path: "Second.txt")
        try Data("first document".utf8).write(to: first)
        try Data("second document".utf8).write(to: second)
        var options = ToolOptions()
        options.documents.target = .html
        options.documents.filenamePattern = "Same"
        let report = try await ToolRunner.run(
            .convertDocuments, inputs: [first, second], destination: directory, imageSize: 0, options: options
        ) { _ in }
        #expect(report.outputs.count == 1)
        #expect(report.failures.count == 1)
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Same.html")
        #expect(try String(contentsOf: output, encoding: .utf8).contains("first document"))
        #expect(try String(contentsOf: second, encoding: .utf8) == "second document")
    }

    @Test func expansionRejectsInvalidNamesAndReportsUnsupportedPairsAndMissingEngines() throws {
        let base = URL(fileURLWithPath: "/tmp/My {index} résumé.docx")
        var options = DocumentConvertOptions()
        options.target = .odt
        options.filenamePattern = "{index} - {name}.odt"
        #expect(try DocumentConvert.outputStem(base, position: 3, options: options) == "3 - My {index} résumé")
        #expect(DocumentConvert.optionIssue(for: base, options: options)?.contains("Pandoc") == true)
        options.target = .docx
        #expect(DocumentConvert.optionIssue(for: base, options: options)?.contains("different") == true)
        options.filenamePattern = "../{name}"
        #expect(throws: ToolError.self) { try DocumentConvert.outputStem(base, position: 1, options: options) }
        options.target = .markdown
        let oldWord = URL(fileURLWithPath: "/tmp/legacy.doc")
        #expect(try DocumentConvert.requiredEngine(for: oldWord, options: options) == .both)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_PANDOC_TEST"] != nil))
    func pandocKeepsHeadingsLinksBoldAndUnicodeAcrossRichFormats() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "Rich.md")
        try Data("# Café — 東京\n\n**Bold words** and [Reference](https://example.test/source).\n".utf8)
            .write(to: source)
        var options = DocumentConvertOptions()
        options.pandocExecutable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_PANDOC_TEST"]))
        var input = source
        for format in [DocumentConvertOptions.Format.docx, .odt, .rtf, .html] {
            options.target = format
            let output = directory.appending(path: "Converted." + format.fileExtension)
            _ = try await DocumentConvert.export(input, to: output, options: options) { _ in }
            input = output
        }
        let html = try String(contentsOf: input, encoding: .utf8)
        #expect(html.contains("Café — 東京"))
        #expect(html.contains("<strong>Bold words</strong>"))
        #expect(html.contains("href=\"https://example.test/source\""))
        #expect(html.contains("<h1"))

        options.target = .plain
        let plain = try await DocumentConvert.preview(input, options: options)
        #expect(plain.text.contains("Bold words") && !plain.text.contains("<strong>"))
        #expect(!plain.text.contains("https://example.test/source"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_PANDOC_TEST"] != nil))
    func pandocEmbedsOfficeImagesInHTMLAndRejectsDanglingAssets() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = directory.appending(path: "Embedded.md")
        let data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2XxkAAAAASUVORK5CYII="
        try Data("![Pixel](data:image/png;base64,\(data))\n".utf8).write(to: markdown)
        var options = DocumentConvertOptions()
        options.pandocExecutable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_PANDOC_TEST"]))
        let docx = directory.appending(path: "Embedded.docx")
        _ = try await DocumentConvert.export(markdown, to: docx, options: options) { _ in }

        options.target = .html
        let html = directory.appending(path: "Embedded.html")
        _ = try await DocumentConvert.export(docx, to: html, options: options) { _ in }
        #expect(try String(contentsOf: html, encoding: .utf8).contains("src=\"data:image/png;base64,"))

        options.target = .markdown
        let refused = directory.appending(path: "Refused.md")
        await #expect(throws: ToolError.self) {
            try await DocumentConvert.export(docx, to: refused, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: refused.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"] != nil))
    func libreOfficeConvertsRTFAndProducesReadablePlainPreview() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rtf = directory.appending(path: "Sample.rtf")
        try Data("{\\rtf1\\ansi Caf\\u233? \\b bold\\b0 \\par}".utf8).write(to: rtf)
        var options = DocumentConvertOptions()
        options.target = .docx
        options.prefersLibreOffice = true
        options.libreOfficeExecutable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_LIBREOFFICE_TEST"]))
        let preview = try await DocumentConvert.preview(rtf, options: options)
        #expect(preview.text.contains("Café") && preview.text.contains("bold"))
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
