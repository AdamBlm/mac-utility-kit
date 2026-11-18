import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Suite struct MarkdownPDFTests {
    @Test func parsesGFMAndOmitsActiveContent() async throws {
        let document = try await MarkdownPDF.prepare("""
        # Heading — café

        [Official guide](https://example.test/guide)

        [Unsafe link](javascript:alert)

        | Name | Value |
        | ---- | ----- |
        | Alpha | 42 |

        ```swift
        print("<tag>")
        ```

        <script>alert("unsafe")</script>
        <img src="https://example.test/tracker.png">

        ![A remote pixel](https://example.test/a.png)
        """)
        #expect(document.html.contains("<h1 id=\"heading--café\">"))
        #expect(document.html.contains("Heading — café"))
        #expect(document.html.contains("https://example.test/guide"))
        #expect(document.html.contains("<table>"))
        #expect(document.html.contains("print(&quot;&lt;tag&gt;&quot;)"))
        #expect(!document.html.contains("<script"))
        #expect(!document.html.contains("tracker.png"))
        #expect(!document.html.contains("javascript:"))
        #expect(!document.html.contains("https://example.test/a.png"))
        #expect(document.imageIssues.count == 1)
    }

    @Test func resolvesImagesOnlyFromExplicitFolderAndReportsBlockedResources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let assets = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.png")
        let local = assets.appendingPathComponent("valid image.png")
        try createPNG(local)
        try createPNG(outside)
        try createPNG(assets.appendingPathComponent("too-wide.png"), width: 17_000)
        let symlink = assets.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let source = """
        ![Local](valid%20image.png)

        ![Traversal](%2E%2E/outside.png)

        ![Symlink](link.png)

        ![Absolute](\(outside.path))

        ![Missing](missing.png)

        ![Oversized](too-wide.png)
        """
        let without = try await MarkdownPDF.prepare(source)
        #expect(!without.html.contains("data:image/png;base64,"))
        var options = MarkdownPDFOptions()
        options.imageFolder = assets
        let prepared = try await MarkdownPDF.prepare(source, options: options)
        #expect(prepared.html.components(separatedBy: "data:image/png;base64,").count == 2)
        #expect(prepared.html.contains("alt=\"Local\""))
        #expect(prepared.imageIssues.count == 5)
        #expect(prepared.imageIssues.contains(where: { $0.contains("Unsupported image dimensions") }))
        #expect(prepared.imageIssues.contains(where: { $0.contains("outside the chosen folder") }))
        #expect(prepared.imageIssues.contains(where: { $0.contains("missing.png") }))
    }

    @MainActor
    @Test func printsSearchablePaginatedPDFWithAPreservedLinkAndWrappedCode() async throws {
        var options = MarkdownPDFOptions()
        options.paper = .letter
        options.margin = .compact
        var source = "# Searchable — café\n\n[Source link](https://example.test/guide)\n\n"
        source += "```text\n" + String(repeating: "longcode", count: 60) + "CODETAIL\n```\n"
        for index in 1...100 {
            source += "\n\nParagraph \(index) marker. " + String(repeating: "Readable text for pagination. ", count: 6)
        }
        let document = try await MarkdownPDF.prepare(source, options: options)
        let bytes = try await MarkdownPDFPrint.render(document)
        let pdf = try #require(PDFDocument(data: bytes))
        #expect(pdf.pageCount > 1)
        let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
        #expect(pages.allSatisfy { abs($0.bounds(for: .mediaBox).width - 612) < 2 && abs($0.bounds(for: .mediaBox).height - 792) < 2 })
        let text = pages.compactMap(\.string).joined(separator: "\n")
        #expect(text.contains("Searchable — café"))
        let heading = try #require(pdf.findString("Searchable", withOptions: []).first)
        let first = try #require(pages.first)
        #expect(abs(heading.bounds(for: first).minX - options.margin.points) < 2)
        #expect(text.filter { !$0.isNewline }.contains("CODETAIL"))
        #expect(text.contains("Paragraph 100 marker"))
        #expect(pages.flatMap(\.annotations).contains { annotation in
            (annotation.action as? PDFActionURL)?.url?.absoluteString == "https://example.test/guide"
        })
    }

    @MainActor
    @Test func duplicateAndUnicodeHeadingLinksReachTheirPrintedPages() async throws {
        var source = "[Duplicate heading](#details-2) · [Unicode heading](#caf%C3%A9) · [Unsafe](javascript:alert%281%29)\n\n# Details\n\nFIRST DETAIL MARKER\n\n# Details-1\n\nLITERAL SUFFIX MARKER"
        let filler = (1...80).map { "Paragraph \($0). " + String(repeating: "Read the printed material. ", count: 8) }
            .joined(separator: "\n\n")
        source += "\n\n" + filler + "\n\n# Details\n\nSECOND DETAIL MARKER\n\n" + filler + "\n\n# Café\n\nUNICODE TARGET MARKER"
        let document = try await MarkdownPDF.prepare(source)
        #expect(document.html.contains("id=\"details\""))
        #expect(document.html.contains("id=\"details-1\""))
        #expect(document.html.contains("id=\"details-2\""))
        #expect(document.html.contains("id=\"café\""))
        #expect(!document.html.contains("javascript:"))
        let printed = try await MarkdownPDFPrint.render(document)
        let pdf = try #require(PDFDocument(data: printed))
        let first = try #require(pdf.page(at: 0))
        let duplicateTarget = try #require(pdf.findString("SECOND DETAIL MARKER").first?.pages.first)
        let unicodeTarget = try #require(pdf.findString("UNICODE TARGET MARKER").first?.pages.first)
        let destinationIndexes = first.annotations.sorted { $0.bounds.minX < $1.bounds.minX }.compactMap { annotation in
            (annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination)?.page
        }.map { pdf.index(for: $0) }
        let duplicate = pdf.index(for: duplicateTarget)
        let unicode = pdf.index(for: unicodeTarget)
        #expect(duplicate > 0 && unicode > duplicate)
        #expect(destinationIndexes == [duplicate, unicode])
        #expect(first.annotations.allSatisfy { $0.url == nil })
    }

    private func createPNG(_ url: URL, width: Int = 24) throws {
        let context = try #require(CGContext(data: nil, width: width, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 12))
        let image = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        try #require(CGImageDestinationFinalize(writer))
    }
}
