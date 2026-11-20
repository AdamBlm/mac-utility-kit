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
        #expect(DocumentConvert.exportIssue(for: first, position: 1, options: options.documents) == nil)
        options.documents.filenamePattern = "../bad"
        #expect(DocumentConvert.exportIssue(for: first, position: 1, options: options.documents)
                == "The filename template produces an invalid filename.")
        options.documents.filenamePattern = "{name}"
        let differentlyCased = directory.appending(path: "FIRST.txt")
        #expect(DocumentConvert.conflictingOutputFilenames([first, differentlyCased], options: options.documents) == ["First.html"])
        options.documents.filenamePattern = "{index} - {name}"
        #expect(DocumentConvert.conflictingOutputFilenames([first, differentlyCased], options: options.documents).isEmpty)
        options.documents.filenamePattern = "Same"
        #expect(DocumentConvert.conflictingOutputFilenames([first, second], options: options.documents) == ["Same.html"])
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

    @Test func exportPreflightRejectsDirectoriesAndOversizedInputs() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeDocument = directory.appending(path: "Folder.txt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeDocument, withIntermediateDirectories: false)
        let large = directory.appending(path: "Large.txt")
        try Data().write(to: large)
        let file = try FileHandle(forWritingTo: large)
        try file.truncate(atOffset: 128 * 1024 * 1024 + 1)
        try file.close()
        var options = DocumentConvertOptions()
        options.target = .html
        for input in [fakeDocument, large] {
            #expect(DocumentConvert.previewIssue(for: input, options: options)
                    == "Choose a local document up to 128 MB.")
            #expect(DocumentConvert.exportIssue(for: input, position: 1, options: options)
                    == "Choose a local document up to 128 MB.")
        }
    }

    @Test func expansionRejectsInvalidNamesAndReportsUnsupportedPairsAndMissingEngines() throws {
        let base = URL(fileURLWithPath: "/tmp/My {index} résumé.docx")
        var options = DocumentConvertOptions()
        options.target = .odt
        options.filenamePattern = "{index} - {name}.odt"
        #expect(try DocumentConvert.outputStem(base, position: 3, options: options) == "3 - My {index} résumé")
        #expect(DocumentConvert.optionIssue(for: base, options: options)?.contains("Pandoc") == true)
        options.pandocExecutable = FileManager.default.temporaryDirectory
        #expect(DocumentConvert.optionIssue(for: base, options: options)?.contains("Pandoc") == true)
        options.target = .docx
        #expect(DocumentConvert.optionIssue(for: base, options: options)?.contains("different") == true)
        options.filenamePattern = "../{name}"
        #expect(throws: ToolError.self) { try DocumentConvert.outputStem(base, position: 1, options: options) }
        let longStem = String(repeating: "é", count: 84)
        options.filenamePattern = "{name}"
        let longInput = URL(fileURLWithPath: "/tmp/" + longStem + ".txt")
        let error = #expect(throws: ToolError.self) {
            try DocumentConvert.outputStem(longInput, position: 3, options: options)
        }
        #expect(error?.localizedDescription.contains("filename is too long") == true)
        options.filenamePattern = DocumentConvertOptions().filenamePattern
        #expect(try DocumentConvert.outputStem(longInput, position: 3, options: options)
                == "3 - " + String(longStem.prefix(82)))
        options.target = .markdown
        let oldWord = URL(fileURLWithPath: "/tmp/legacy.doc")
        #expect(try DocumentConvert.requiredEngine(for: oldWord, options: options) == .both)
    }

    @Test func compatiblePairsUseAvailableEnginesAndKeepThePreferredEngineWhenBothWork() throws {
        let input = URL(fileURLWithPath: "/tmp/source.rtf")
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let installed = URL(fileURLWithPath: "/usr/bin/true")
        var options = DocumentConvertOptions()
        options.target = .docx
        options.prefersLibreOffice = true
        options.libreOfficeExecutable = missing
        options.pandocExecutable = installed
        #expect(try DocumentConvert.requiredEngine(for: input, options: options) == .pandoc)
        #expect(DocumentConvert.optionIssue(for: input, options: options) == nil)

        options.libreOfficeExecutable = installed
        #expect(try DocumentConvert.requiredEngine(for: input, options: options) == .libreOffice)
        options.prefersLibreOffice = false
        #expect(try DocumentConvert.requiredEngine(for: input, options: options) == .pandoc)
        options.pandocExecutable = missing
        #expect(try DocumentConvert.requiredEngine(for: input, options: options) == .libreOffice)
        #expect(DocumentConvert.optionIssue(for: input, options: options) == nil)

        options.target = .markdown
        #expect(try DocumentConvert.requiredEngine(for: input, options: options) == .pandoc)
        #expect(DocumentConvert.optionIssue(for: input, options: options)?.contains("Pandoc") == true)
    }

    @Test
    func previewTracksTheActualFileAndExportRejectsChangesDuringConversion() async throws {
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Source.txt")
        let output = folder.appending(path: "Output.md")
        try Data("Before edit".utf8).write(to: source)
        var options = DocumentConvertOptions()
        options.target = .markdown
        let preview = try await DocumentConvert.preview(source, options: options)
        #expect(preview.matchesSource(source))
        try Data("After edit".utf8).write(to: source, options: .atomic)
        #expect(!preview.matchesSource(source))
        await #expect(throws: ToolError.self) {
            try await DocumentConvert.export(source, to: output, options: options) { fraction in
                if fraction == 0.15 {
                    do { try Data("Changed during export".utf8).write(to: source, options: .atomic) }
                    catch { Issue.record("Could not replace the fixture: \(error)") }
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_PANDOC_TEST"] != nil))
    func previewAndExportUsePandocWhenPreferredLibreOfficeIsMissing() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "Document.rtf")
        let output = directory.appending(path: "Document.docx")
        try Data(#"{\rtf1\ansi Routing fixture}"#.utf8).write(to: input)

        var options = DocumentConvertOptions()
        options.prefersLibreOffice = true
        options.libreOfficeExecutable = directory.appending(path: "Missing.app")
        options.pandocExecutable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_PANDOC_TEST"]))
        #expect(try await DocumentConvert.preview(input, options: options).text.contains("Routing fixture"))
        let summary = try await DocumentConvert.export(input, to: output, options: options) { _ in }
        #expect(summary.hasSuffix("Pandoc"))
        #expect(FileManager.default.fileExists(atPath: output.path))

        let linkedPandoc = directory.appending(path: "pandoc")
        try FileManager.default.createSymbolicLink(at: linkedPandoc, withDestinationURL: try #require(options.pandocExecutable))
        options.pandocExecutable = linkedPandoc
        options.libreOfficeExecutable = URL(fileURLWithPath: "/usr/bin/true")
        options.prefersLibreOffice = false
        let preview = try await DocumentConvert.preview(input, options: options)
        #expect(preview.matchesConversion(input, options: options))
        try FileManager.default.removeItem(at: linkedPandoc)
        #expect(preview.matchesSource(input))
        #expect(!preview.matchesConversion(input, options: options))
    }

    @Test(arguments: [DocumentConvertOptions.Format.docx, .odt])
    func rejectsWrongOfficePackagesBeforePublishing(format: DocumentConvertOptions.Format) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "Original.md")
        try Data("Document text".utf8).write(to: input)

        let mimetype = directory.appending(path: "mimetype")
        let content = directory.appending(path: "content.xml")
        let metadata = directory.appending(path: "META-INF")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        try Data("application/vnd.oasis.opendocument.test".utf8).write(to: mimetype)
        try Data("<document-content/>".utf8).write(to: content)
        try Data("<manifest/>".utf8).write(to: metadata.appending(path: "manifest.xml"))
        try await ArchiveTools.create([mimetype, content, metadata], to: directory.appending(path: "Wrong.zip"))

        let engine = directory.appending(path: "wrong-package-engine")
        try Data("""
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --log) shift; printf '[]' > "$1" ;;
                --output) shift; target="$1" ;;
              esac
              shift
            done
            exec /bin/cp "${0%/*}/Wrong.zip" "$target"
            """.utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        var options = DocumentConvertOptions()
        options.target = format
        options.pandocExecutable = engine
        let output = directory.appending(path: "Output.\(format.fileExtension)")
        do {
            _ = try await DocumentConvert.export(input, to: output, options: options) { _ in }
            Issue.record("Conversion published the wrong Office package.")
        } catch {
            #expect(error.localizedDescription.contains("required \(format.rawValue) document parts"))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
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
        options.target = .odt
        let output = directory.appending(path: "Converted.odt")
        _ = try await DocumentConvert.export(rtf, to: output, options: options) { _ in }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
