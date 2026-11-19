import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Test func textExtractionRecognizesImageAndTopLeftRegion() async throws {
    let folder = try textExtractionFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("sample.png")
    try writeTextExtractionImage(to: source)
    let original = try Data(contentsOf: source)
    var options = TextExtractionOptions()
    options.language = "en-US"

    let whole = try await TextExtraction.extract(source, options: options)
    #expect(whole.text.contains("UPPER ORCHARD"))
    #expect(whole.text.contains("LOWER MEADOW"))
    let upperLine = try #require(whole.text.range(of: "UPPER ORCHARD"))
    let lowerLine = try #require(whole.text.range(of: "LOWER MEADOW"))
    #expect(upperLine.lowerBound < lowerLine.lowerBound)
    options.region = CGRect(x: 0, y: 0, width: 1, height: 0.5)
    let upper = try await TextExtraction.extract(source, options: options)
    #expect(upper.text.contains("UPPER ORCHARD"))
    #expect(!upper.text.contains("LOWER MEADOW"))
    #expect(try Data(contentsOf: source) == original)
}

@Test func textExtractionHandlesScannedAndEmbeddedPDFText() async throws {
    let folder = try textExtractionFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appendingPathComponent("scan.png")
    try writeTextExtractionImage(to: image)
    let scan = folder.appendingPathComponent("scan.pdf")
    try await ImagesToPDF.export([image], to: scan, options: .init()) { _ in }
    let embedded = folder.appendingPathComponent("embedded.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    let context = try #require(CGContext(embedded as CFURL, mediaBox: &bounds, nil))
    for line in ["FIRST DOCUMENT PAGE", "SECOND DOCUMENT PAGE"] {
        context.beginPDFPage(nil)
        drawOCRFixture(line, in: context, at: .init(x: 35, y: 150))
        context.endPDFPage()
    }
    context.closePDF()

    var options = TextExtractionOptions()
    options.language = "en-US"
    let scanned = try await TextExtraction.extract(scan, options: options)
    #expect(scanned.pages.first?.pageNumber == 1)
    #expect(scanned.text.contains("UPPER ORCHARD"))
    #expect(scanned.pages.first?.error == nil)
    options.range = "2, 1"
    let extracted = try await TextExtraction.extract(embedded, options: options)
    #expect(extracted.pages.compactMap(\.pageNumber) == [2, 1])
    #expect(extracted.pages.first?.text == "SECOND DOCUMENT PAGE")
    #expect(extracted.text.contains("Page 2\n\nSECOND DOCUMENT PAGE\n\u{000C}\nPage 1"))
    options.includePageBreaks = false
    let withoutBreaks = try await TextExtraction.extract(embedded, options: options)
    #expect(withoutBreaks.text == "SECOND DOCUMENT PAGE\n\nFIRST DOCUMENT PAGE")
    options.preferEmbeddedText = false
    options.range = "2"
    let forcedOCR = try await TextExtraction.extract(embedded, options: options)
    #expect(forcedOCR.text.contains("SECOND DOCUMENT PAGE"))
    #expect(!forcedOCR.text.contains("FIRST DOCUMENT PAGE"))
}

@Test func textExtractionRejectsPDFReplacedBetweenPages() async throws {
    let folder = try textExtractionFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.pdf")
    let replacement = folder.appendingPathComponent("replacement.pdf")
    for (file, marker) in [(source, "ORIGINAL"), (replacement, "REPLACEMENT")] {
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
        for number in 1...2 {
            context.beginPDFPage(nil)
            drawOCRFixture("\(marker) PAGE \(number)", in: context, at: .init(x: 35, y: 150))
            context.endPDFPage()
        }
        context.closePDF()
    }
    let replacementBytes = try Data(contentsOf: replacement)
    var options = TextExtractionOptions()
    options.language = "en-US"
    options.preferEmbeddedText = false
    let failure = await #expect(throws: ToolError.self) {
        try await TextExtraction.extract(source, options: options) { fraction in
            if fraction == 0.5 {
                try? replacementBytes.write(to: source, options: .atomic)
            }
        }
    }
    #expect(failure?.localizedDescription.contains("source PDF changed") == true)
    #expect(try Data(contentsOf: source) == replacementBytes)
}

@Test func textExtractionRejectsUnknownLanguagesAndOffPageRegions() async throws {
    let folder = try textExtractionFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("sample.png")
    try writeTextExtractionImage(to: source)
    var options = TextExtractionOptions()
    options.language = "invalid-language"
    await #expect(throws: ToolError.self) { try await TextExtraction.extract(source, options: options) }
    options.language = nil
    options.region = CGRect(x: -0.2, y: 0, width: 0.8, height: 1)
    await #expect(throws: ToolError.self) { try await TextExtraction.extract(source, options: options) }
}

@Test func textExtractionRespectsEncryptedPDFCopyPermissions() async throws {
    let folder = try textExtractionFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let plain = folder.appendingPathComponent("plain.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    let context = try #require(CGContext(plain as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    drawOCRFixture("PROTECTED TEXT", in: context, at: .init(x: 35, y: 150))
    context.endPDFPage()
    context.closePDF()
    let source = try #require(PDFDocument(url: plain))
    let encrypted = folder.appendingPathComponent("protected.pdf")
    let ciphertext = try #require(source.dataRepresentation(options: [
        PDFDocumentWriteOption.userPasswordOption: "reader",
        PDFDocumentWriteOption.ownerPasswordOption: "owner",
        PDFDocumentWriteOption.accessPermissionsOption: 0
    ]))
    try ciphertext.write(to: encrypted)

    var options = TextExtractionOptions()
    options.password = "reader"
    await #expect(throws: ToolError.self) { try await TextExtraction.extract(encrypted, options: options) }
    options.password = "owner"
    let readable = try await TextExtraction.extract(encrypted, options: options)
    #expect(readable.text.contains("PROTECTED TEXT"))
    options.range = "2"
    await #expect(throws: ToolError.self) { try await TextExtraction.extract(encrypted, options: options) }
    #expect(try Data(contentsOf: encrypted) == ciphertext)
}

private func textExtractionFixtureFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func writeTextExtractionImage(to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil, width: 720, height: 440, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 720, height: 440))
    drawOCRFixture("UPPER ORCHARD", in: context, at: .init(x: 55, y: 305))
    drawOCRFixture("LOWER MEADOW", in: context, at: .init(x: 55, y: 85))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
}

private func drawOCRFixture(_ string: String, in context: CGContext, at point: CGPoint) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ]))
    context.textPosition = point
    CTLineDraw(line, context)
}
