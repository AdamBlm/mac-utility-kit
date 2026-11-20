import CoreGraphics
import CoreText
import PDFKit
import Testing
import Vision
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
        let recognitionRaster = try SearchablePDFTextLayer.rasterize(before, limit: 4_096)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: recognitionRaster.image).perform([request])
        let phrase = try #require(request.results?.first {
            $0.topCandidates(1).first?.string == "Searchable sample 7429"
        }?.boundingBox)
        let overlap = normalized.intersection(phrase)
        #expect(!overlap.isNull)
        #expect(overlap.width >= phrase.width * 0.8)
        #expect(overlap.height >= min(normalized.height, phrase.height) * 0.6)
        #expect(phrase.minX...phrase.maxX ~= normalized.midX)
    }

    @Test
    func previewsPagesAndRecognizedTextFromEachSourceInABatch() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scan = folder.appending(path: "Scan.pdf")
        let native = folder.appending(path: "Native.pdf")
        try Self.makeScan(to: scan, rotation: 0)
        try Self.pdf { context in
            Self.draw("Second document", in: context, at: CGPoint(x: 100, y: 200), size: 20)
        }.write(to: native)
        var options = SearchablePDFOptions()
        options.range = "1"
        options.language = "en-US"
        #expect(try await SearchablePDF.pageNumbers(scan, options: options) == [1])
        #expect(try await SearchablePDF.pageNumbers(native, options: options) == [1])
        let scannedPreview = try await SearchablePDF.preview(scan, pageNumber: 1, options: options)
        let nativePreview = try await SearchablePDF.preview(native, pageNumber: 1, options: options)
        #expect(scannedPreview.result.text.contains("Searchable sample 7429"))
        #expect(nativePreview.result.text.contains("Second document"))
        #expect(nativePreview.result.status == .alreadySearchable)
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
    func alreadySearchableSymlinkExportsAnIndependentByteIdenticalPDF() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.pdf")
        let alias = folder.appending(path: "alias.pdf")
        let output = folder.appending(path: "output.pdf")
        let original = try Self.pdf { context in
            Self.draw("Existing native text", in: context, at: CGPoint(x: 100, y: 200), size: 20)
        }
        try original.write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let report = try await SearchablePDF.export(alias, to: output, options: .init()) { _ in }

        #expect(report.pages.map(\.status) == [.alreadySearchable])
        let sourceText = try #require(PDFDocument(url: source)?.page(at: 0)?.string)
        #expect(sourceText.trimmingCharacters(in: .whitespacesAndNewlines) == "Existing native text")
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: output) == original)
        #expect(PDFDocument(url: output)?.page(at: 0)?.string == sourceText)
    }

    @Test(arguments: [false, true])
    func rejectsSourceReplacementDuringRecognition(addsOCR: Bool) async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.pdf")
        let output = folder.appending(path: "output.pdf")
        let native = try Self.pdf { context in
            Self.draw("Existing native text", in: context, at: CGPoint(x: 100, y: 200), size: 20)
        }
        if addsOCR {
            try Self.makeScan(to: source, rotation: 0)
        } else {
            try native.write(to: source)
        }
        let replacement = try Self.pdf { context in
            Self.draw("Replacement", in: context, at: CGPoint(x: 100, y: 200), size: 20)
        }
        do {
            _ = try await SearchablePDF.export(source, to: output, options: .init()) { fraction in
                if fraction == 0.9 {
                    do { try replacement.write(to: source, options: .atomic) }
                    catch { Issue.record("Could not replace the source fixture: \(error)") }
                }
            }
            Issue.record("Searchable PDF published output after its source changed.")
        } catch {
            #expect(error.localizedDescription.contains("source PDF changed"))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: source) == replacement)
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

    @Test(arguments: [0, 90])
    func deduplicatesEmbeddedTextSharingABaselineWithScannedTextAndRerunsIdempotently(rotation: Int) async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Mixed.pdf")
        let searchable = folder.appending(path: "Searchable.pdf")
        let repeated = folder.appending(path: "Repeated.pdf")
        try Self.makeSameLineScan(to: source, rotation: rotation)
        let document = try #require(PDFDocument(url: source))
        #expect(document.findString("Native label").count == 1)
        #expect(document.findString("Scanned 7429").isEmpty)

        var options = SearchablePDFOptions()
        options.skipsSearchablePages = false
        options.language = "en-US"
        let preview = try await SearchablePDF.preview(source, pageNumber: 1, options: options)
        #expect(preview.result.text.components(separatedBy: "Native label").count == 2)
        #expect(preview.result.text.components(separatedBy: "Scanned 7429").count == 2)
        let scanned = try #require(preview.result.text.range(of: "Scanned 7429"))
        let footer = try #require(preview.result.text.range(of: "NATIVE FOOTER"))
        #expect(scanned.lowerBound < footer.lowerBound)
        let report = try await SearchablePDF.export(source, to: searchable, options: options) { _ in }
        #expect(report.pages.first?.status == .addedText)
        let second = try await SearchablePDF.export(searchable, to: repeated, options: options) { _ in }
        #expect(second.pages.first?.status == .alreadySearchable)
        #expect(try Data(contentsOf: searchable) == Data(contentsOf: repeated))

        let originalPage = try #require(document.page(at: 0))
        let originalRaster = try SearchablePDFTextLayer.rasterize(originalPage, limit: 600)
        let expectedPixels = try Self.bytes(originalRaster.image)
        for output in [searchable, repeated] {
            let result = try #require(PDFDocument(url: output))
            #expect(result.findString("Native label").count == 1)
            #expect(result.findString("Scanned 7429").count == 1)
            let page = try #require(result.page(at: 0))
            #expect(page.rotation == rotation)
            #expect(page.bounds(for: .cropBox).size == originalPage.bounds(for: .cropBox).size)
            let pixels = try SearchablePDFTextLayer.rasterize(page, limit: 600)
            #expect(try Self.bytes(pixels.image) == expectedPixels)
        }
    }

    @Test(arguments: ["Incorrect archive 0000", "Searchable archive 0000"])
    func recognizesVisibleScanTextUnderADifferentInvisibleTextLayer(staleText: String) async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "Original.pdf")
        let stale = folder.appending(path: "Stale.pdf")
        let corrected = folder.appending(path: "Corrected.pdf")
        let repeated = folder.appending(path: "Repeated.pdf")
        try Self.makeScan(to: original, rotation: 90)
        let source = try #require(PDFDocument(url: original))
        let page = try #require(source.page(at: 0))
        let raster = try SearchablePDFTextLayer.rasterize(page, limit: 600)
        let layer = try SearchablePDFTextLayer.pageWithText(page, raster: raster, lines: [
            .init(text: staleText, bounds: CGRect(x: 0.13, y: 0.61, width: 0.83, height: 0.08))
        ])
        let staleDocument = PDFDocument()
        staleDocument.insert(layer, at: 0)
        try #require(staleDocument.write(to: stale))
        let reopened = try #require(PDFDocument(url: stale))
        #expect(reopened.findString(staleText).count == 1)
        #expect(reopened.findString("Searchable sample 7429").isEmpty)

        var options = SearchablePDFOptions()
        options.skipsSearchablePages = false
        options.language = "en-US"
        let report = try await SearchablePDF.export(stale, to: corrected, options: options) { _ in }
        #expect(report.pages.first?.status == .addedText)
        let verified = try #require(PDFDocument(url: corrected))
        #expect(verified.findString("Searchable sample 7429").count == 1)
        #expect(verified.findString(staleText).count == 1)
        let result = try #require(verified.page(at: 0))
        #expect(try Self.bytes(SearchablePDFTextLayer.rasterize(result, limit: 600).image) == Self.bytes(raster.image))

        let repeatReport = try await SearchablePDF.export(corrected, to: repeated, options: options) { _ in }
        #expect(repeatReport.pages.first?.status == .alreadySearchable)
        #expect(try Data(contentsOf: corrected) == Data(contentsOf: repeated))
    }

    private static func makeSameLineScan(to url: URL, rotation: Int) throws {
        let template = try #require(PDFDocument(data: pdf { _ in }))
        let emptyPage = try #require(template.page(at: 0))
        emptyPage.rotation = rotation
        let data = try #require(template.dataRepresentation())
        let provider = try #require(CGDataProvider(data: data as CFData))
        let pageRef = try #require(CGPDFDocument(provider)?.page(at: 1))
        let canvas = CGRect(x: 0, y: 0, width: rotation == 90 ? crop.height : crop.width,
                            height: rotation == 90 ? crop.width : crop.height)
        let transform = pageRef.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true)
        let bitmap = try #require(CGContext(data: nil, width: 720, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(.white)
        bitmap.fill(CGRect(x: 0, y: 0, width: 720, height: 180))
        bitmap.scaleBy(x: 4, y: 4)
        Self.draw("Scanned 7429", in: bitmap, at: CGPoint(x: 0, y: 14), size: 24)
        let image = try #require(bitmap.makeImage())
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Native label", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let x: CGFloat = 36
        let y: CGFloat = 210
        let source = try #require(PDFDocument(data: pdf { page in
            page.concatenate(transform.inverted())
            Self.draw("Native label", in: page, at: CGPoint(x: x, y: y), size: 24)
            page.draw(image, in: CGRect(x: x + width + 4, y: y - 14, width: 180, height: 45))
            Self.draw("NATIVE FOOTER", in: page, at: CGPoint(x: x, y: 45), size: 19)
        }))
        let page = try #require(source.page(at: 0))
        page.rotation = rotation
        try #require(source.write(to: url))
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
