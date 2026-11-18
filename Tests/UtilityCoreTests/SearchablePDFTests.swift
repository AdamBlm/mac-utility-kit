import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import UtilityCore

@Suite(.serialized)
struct SearchablePDFTests {
    @Test(arguments: [0, 90, 180, 270])
    func ocrPreservesAppearanceAndPositionForCroppedRotatedPage(rotation: Int) async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "input.pdf")
        let output = folder.appending(path: "output.pdf")
        try Self.makeScan(to: source, rotation: rotation)

        var options = SearchablePDFOptions()
        options.language = "en-US"
        let report = try await SearchablePDF.export(source, to: output, options: options) { _ in }
        #expect(report.pages.first?.status == .addedText)
        #expect(report.pages.first?.text.contains("Searchable sample") == true)
        let original = try #require(PDFDocument(url: source))
        let result = try #require(PDFDocument(url: output))
        let before = try #require(original.page(at: 0))
        let after = try #require(result.page(at: 0))
        #expect(after.rotation == before.rotation)
        let beforeMedia = before.bounds(for: .mediaBox)
        let afterMedia = after.bounds(for: .mediaBox)
        #expect(afterMedia.size == beforeMedia.size)
        #expect(after.bounds(for: .cropBox).offsetBy(dx: -afterMedia.minX, dy: -afterMedia.minY)
                == before.bounds(for: .cropBox).offsetBy(dx: -beforeMedia.minX, dy: -beforeMedia.minY))
        #expect(after.string?.contains("Searchable sample 7429") == true)
        let hit = try #require(result.findString("Searchable sample 7429").first)
        #expect(hit.string == "Searchable sample 7429")

        let pixels = try SearchablePDFTextLayer.rasterize(before, limit: 600)
        let rewritten = try SearchablePDFTextLayer.rasterize(after, limit: 600)
        #expect(try Self.bytes(pixels.image) == Self.bytes(rewritten.image))
        let selection = hit.bounds(for: after).applying(rewritten.rasterToPage.inverted())
        let normalized = CGRect(x: selection.minX / pixels.bounds.width,
                                y: selection.minY / pixels.bounds.height,
                                width: selection.width / pixels.bounds.width,
                                height: selection.height / pixels.bounds.height)
        #expect(abs(normalized.minX - 0.13) < 0.025)
        #expect(abs(normalized.minY - 0.60) < 0.06)
    }

    @Test
    func keepsExcludedAndSearchablePagesAndReportsBlankScans() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scan = folder.appending(path: "scan.pdf")
        let source = folder.appending(path: "selected.pdf")
        let output = folder.appending(path: "output.pdf")
        try Self.makeScan(to: scan, rotation: 0)
        let sources = try #require(PDFDocument(url: scan))
        let scanned = try #require(sources.page(at: 0))
        let nativePDF = try #require(PDFDocument(data: Self.pdf { context in
            Self.draw("Existing native text", in: context, at: CGPoint(x: 100, y: 200), size: 20)
        }))
        let existing = try #require(nativePDF.page(at: 0))
        let emptyPDF = try #require(PDFDocument(data: Self.pdf { _ in }))
        let empty = try #require(emptyPDF.page(at: 0))
        let document = PDFDocument()
        for page in [scanned, existing, empty, try #require(scanned.copy() as? PDFPage)] {
            document.insert(page, at: document.pageCount)
        }
        #expect(document.write(to: source))
        var options = SearchablePDFOptions()
        options.range = "1-3"
        let report = try await SearchablePDF.export(source, to: output, options: options) { _ in }
        #expect(report.pages.map(\.status) == [.addedText, .alreadySearchable, .noText])
        #expect(report.warnings == ["Page 3: No text recognized."])
        let exported = try #require(PDFDocument(url: output))
        #expect(exported.pageCount == 4)
        #expect(exported.page(at: 1)?.string == "Existing native text")
        #expect(exported.page(at: 3)?.string?.isEmpty != false)
    }

    @Test
    func rescansMixedPagesWithoutDuplicatingEmbeddedTextAndPreservesLinks() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appending(path: "mixed.pdf")
        let source = folder.appending(path: "source.pdf")
        let output = folder.appending(path: "output.pdf")
        try Self.makeScan(to: base, rotation: 0, addsEmbeddedText: true)
        let sourcePDF = try #require(PDFDocument(url: base))
        let page = try #require(sourcePDF.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 110, y: 90, width: 60, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: try #require(URL(string: "https://example.com")))
        page.addAnnotation(link)
        #expect(sourcePDF.write(to: source))

        var options = SearchablePDFOptions()
        options.skipsSearchablePages = false
        let report = try await SearchablePDF.export(source, to: output, options: options) { _ in }
        #expect(report.pages.first?.status == .addedText)
        let result = try #require(PDFDocument(url: output))
        #expect(result.findString("Existing native text").count == 1)
        #expect(result.findString("Searchable sample 7429").count == 1)
        let annotatedPage = try #require(result.page(at: 0))
        let urlAction = annotatedPage.annotations.first?.action as? PDFActionURL
        #expect(urlAction?.url?.absoluteString == "https://example.com")
    }

    private static let media = CGRect(x: 10, y: 15, width: 490, height: 400)
    private static let crop = CGRect(x: 50, y: 45, width: 420, height: 340)

    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private static func makeScan(to url: URL, rotation: Int, addsEmbeddedText: Bool = false) throws {
        let template = try #require(PDFDocument(data: pdf { _ in }))
        let direction = try #require(template.page(at: 0))
        direction.rotation = rotation
        let serialized = try #require(template.dataRepresentation())
        let raw = try #require(CGPDFDocument(CGDataProvider(data: serialized as CFData)!))
        let ref = try #require(raw.page(at: 1))
        let swapped = rotation == 90 || rotation == 270
        let canvas = CGRect(x: 0, y: 0, width: swapped ? crop.height : crop.width,
                            height: swapped ? crop.width : crop.height)
        let transform = ref.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true)
        let quality = 3
        let imageWidth = Int(canvas.width) * quality
        let imageHeight = Int(canvas.height) * quality
        let bitmap = try #require(CGContext(data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.scaleBy(x: CGFloat(quality), y: CGFloat(quality))
        bitmap.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.86, alpha: 1))
        bitmap.fill(canvas)
        bitmap.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.65, alpha: 1))
        bitmap.fill(CGRect(x: 14, y: 18, width: 40, height: 21))
        draw("Searchable sample 7429", in: bitmap, at: CGPoint(x: canvas.width * 0.13, y: canvas.height * 0.62),
             size: canvas.width * 0.075)
        let image = try #require(bitmap.makeImage())
        let source = try #require(PDFDocument(data: pdf { context in
            context.concatenate(transform.inverted())
            context.draw(image, in: canvas)
            if addsEmbeddedText {
                draw("Existing native text", in: context, at: CGPoint(x: canvas.width * 0.18, y: canvas.height * 0.31), size: 20)
            }
        }))
        try #require(source.page(at: 0)).rotation = rotation
        #expect(source.write(to: url))
    }

    private static func pdf(_ content: (CGContext) -> Void) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var box = media
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let entries: [CFString: Data] = [kCGPDFContextCropBox: withUnsafeBytes(of: crop) { Data($0) }]
        context.beginPDFPage(entries as CFDictionary)
        content(context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }

    private static func bytes(_ image: CGImage) throws -> Data {
        try #require(image.dataProvider?.data) as Data
    }
}
