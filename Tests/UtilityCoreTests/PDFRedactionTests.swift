import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import UtilityCore

@Suite(.serialized)
struct PDFRedactionTests {
    @Test func adjacentMarkedPagesSkipUnmarkedPagesAndRepeatedMarks() {
        let marks = [7, 2, 5, 2, 7].map {
            PDFRedactionMark(page: $0, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), kind: .region)
        }
        let beforeFirst = PDFRedaction.adjacentMarkedPages(to: 1, in: marks)
        #expect(beforeFirst.previous == nil && beforeFirst.next == 2)
        let onMarked = PDFRedaction.adjacentMarkedPages(to: 5, in: marks)
        #expect(onMarked.previous == 2 && onMarked.next == 7)
        let onUnmarked = PDFRedaction.adjacentMarkedPages(to: 6, in: marks)
        #expect(onUnmarked.previous == 5 && onUnmarked.next == 7)
        let atLast = PDFRedaction.adjacentMarkedPages(to: 7, in: marks)
        #expect(atLast.previous == 5 && atLast.next == nil)
        let empty = PDFRedaction.adjacentMarkedPages(to: 1, in: [])
        #expect(empty.previous == nil && empty.next == nil)
    }

    @Test(arguments: [0, 90, 180, 270])
    func removesTextImagePixelsAndHiddenDataFromRotatedCopies(rotation: Int) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appending(path: "source.pdf")
        let output = folder.appending(path: "redacted.pdf")
        try Self.makePDF(at: sourceURL, rotation: rotation)
        let originalData = try Data(contentsOf: sourceURL)
        let source = try await PDFRedaction.open(sourceURL)
        let matches = try await PDFRedaction.search("private passphrase", in: source)
        try #require(matches.count == 1)
        #expect(matches.first?.page == 1)
        let imageMask = PDFRedactionMark(page: 1, rect: CGRect(x: 0.095, y: 0.43, width: 0.405, height: 0.24), kind: .region)
        let fill: PDFRedactionFill = rotation == 0 || rotation == 180 ? .white : .black

        let report = try await PDFRedaction.export(source, marks: matches + [imageMask], fill: fill, to: output)
        #expect(report.pageCount == 1)
        #expect(report.marks == 2)
        #expect(try Data(contentsOf: sourceURL) == originalData)

        let original = try #require(PDFDocument(url: sourceURL))
        let redacted = try #require(PDFDocument(url: output))
        let before = try #require(original.page(at: 0))
        let after = try #require(redacted.page(at: 0))
        #expect(original.findString("PRIVATE PASSPHRASE").count == 1)
        #expect(!before.annotations.isEmpty)
        #expect((original.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) == "PRIVATE_METADATA")
        #expect((after.string ?? "").isEmpty)
        #expect(after.annotations.isEmpty)
        #expect((redacted.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) != "PRIVATE_METADATA")
        #expect(after.bounds(for: .mediaBox).size == (try PDFRedactionGeometry(before)).displaySize)

        let beforeImage = try Self.render(before)
        let afterImage = try Self.render(after)
        let originalSecret = try Self.pixel(beforeImage, at: CGPoint(x: 0.3, y: 0.55))
        let replaced = try Self.pixel(afterImage, at: CGPoint(x: 0.3, y: 0.55))
        let originalPublic = try Self.pixel(beforeImage, at: CGPoint(x: 0.7, y: 0.55))
        let preserved = try Self.pixel(afterImage, at: CGPoint(x: 0.7, y: 0.55))
        #expect(originalSecret[0] > 220 && originalSecret[1] < 100 && originalSecret[2] > 220)
        #expect(originalPublic[0] < 30 && originalPublic[1] > 180 && originalPublic[2] < 45)
        #expect(zip(originalPublic, preserved).allSatisfy { abs(Int($0) - Int($1)) < 3 })
        #expect(replaced.allSatisfy { fill == .black ? $0 < 3 : $0 > 252 })
        let textMark = try #require(matches.first?.rect)
        let textFill = try Self.pixel(afterImage, at: CGPoint(x: textMark.midX, y: textMark.midY))
        #expect(textFill.allSatisfy { fill == .black ? $0 < 3 : $0 > 252 })

        let dictionary = try #require(after.pageRef?.dictionary)
        var resources: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        let stored = try #require(resources)
        var fonts: CGPDFDictionaryRef?
        #expect(!CGPDFDictionaryGetDictionary(stored, "Font", &fonts) || fonts.map { CGPDFDictionaryGetCount($0) == 0 } == true)
        var images: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(stored, "XObject", &images))
        #expect(images.map(CGPDFDictionaryGetCount) == 1)
    }

    @Test
    func preservesAReplacementAtTheConfirmedRedactionDestination() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "source.pdf")
        let output = folder.appending(path: "redacted.pdf")
        try Self.makePDF(at: input, rotation: 0)
        let source = try await PDFRedaction.open(input)
        let marks = try await PDFRedaction.search("private passphrase", in: source)
        try Data("confirmed initial output".utf8).write(to: output)
        let confirmed = try PDFFormDestination(output, preserving: input)
        let replacement = Data("unrelated replacement".utf8)
        do {
            _ = try await PDFRedaction.export(source, marks: marks, fill: .black, destination: confirmed) { progress in
                if progress < 1 {
                    do { try replacement.write(to: output, options: .atomic) }
                    catch { Issue.record("Could not replace the destination fixture: \(error)") }
                }
            }
            Issue.record("Redaction overwrote an unrelated destination.")
        } catch {
            #expect(error.localizedDescription.contains("destination file changed"))
        }
        #expect(try Data(contentsOf: output) == replacement)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["source.pdf", "redacted.pdf"])
    }

    @Test
    func rejectsSourceOverwriteAndOutOfPageMarks() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appending(path: "source.pdf")
        try Self.makePDF(at: sourceURL, rotation: 0)
        let original = try Data(contentsOf: sourceURL)
        let source = try await PDFRedaction.open(sourceURL)
        let marks = try await PDFRedaction.search("PRIVATE PASSPHRASE", in: source)
        await #expect(throws: ToolError.self) {
            try await PDFRedaction.export(source, marks: marks, fill: .black, to: sourceURL, replacingExisting: true)
        }
        let link = folder.appending(path: "linked.pdf")
        try FileManager.default.linkItem(at: sourceURL, to: link)
        await #expect(throws: ToolError.self) {
            try await PDFRedaction.export(source, marks: marks, fill: .black, to: link, replacingExisting: true)
        }
        let output = folder.appending(path: "invalid.pdf")
        await #expect(throws: ToolError.self) {
            let offPage = PDFRedactionMark(page: 1, rect: CGRect(x: -0.1, y: 0, width: 0.2, height: 0.2), kind: .region)
            return try await PDFRedaction.export(source, marks: [offPage], fill: .white, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    private static let media = CGRect(x: 10, y: 15, width: 350, height: 288)
    private static let crop = CGRect(x: 35, y: 35, width: 300, height: 240)

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private static func makePDF(at url: URL, rotation: Int) throws {
        let reference = try #require(PDFDocument(data: pdf { _ in }))
        let blank = try #require(reference.page(at: 0))
        blank.rotation = rotation
        let serialized = try #require(reference.dataRepresentation())
        let raw = try #require(CGPDFDocument(CGDataProvider(data: serialized as CFData)!))
        let pageRef = try #require(raw.page(at: 1))
        let swapped = rotation == 90 || rotation == 270
        let canvas = CGRect(x: 0, y: 0, width: swapped ? crop.height : crop.width,
                            height: swapped ? crop.width : crop.height)
        let transform = pageRef.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true)
        let bitmap = try Self.context(width: 64, height: 32)
        bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        bitmap.setFillColor(CGColor(red: 0, green: 0.9, blue: 0.05, alpha: 1))
        bitmap.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        let image = try #require(bitmap.makeImage())
        let data = try pdf { context in
            context.concatenate(transform.inverted())
            context.draw(image, in: CGRect(x: canvas.width * 0.1, y: canvas.height * 0.35,
                                           width: canvas.width * 0.8, height: canvas.height * 0.2))
            draw("PRIVATE PASSPHRASE", at: CGPoint(x: canvas.width * 0.15, y: canvas.height * 0.74), in: context)
            draw("Visible public text", at: CGPoint(x: canvas.width * 0.15, y: canvas.height * 0.21), in: context)
        }
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        page.rotation = rotation
        let note = PDFAnnotation(bounds: CGRect(x: 150, y: 100, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "PRIVATE_ANNOTATION"
        page.addAnnotation(note)
        #expect(document.write(to: url))
    }

    private static func pdf(_ render: (CGContext) -> Void) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var box = media
        let info: [CFString: String] = [kCGPDFContextTitle: "PRIVATE_METADATA"]
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary))
        let entries: [CFString: Data] = [kCGPDFContextCropBox: withUnsafeBytes(of: crop) { Data($0) }]
        context.beginPDFPage(entries as CFDictionary)
        render(context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func draw(_ text: String, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    }

    private static func render(_ page: PDFPage) throws -> CGImage {
        let geometry = try PDFRedactionGeometry(page)
        let size = geometry.displaySize
        let bitmap = try context(width: Int(size.width), height: Int(size.height))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(origin: .zero, size: size))
        bitmap.concatenate(geometry.pageToDisplay)
        bitmap.drawPDFPage(try #require(page.pageRef))
        return try #require(bitmap.makeImage())
    }

    private static func pixel(_ image: CGImage, at normalized: CGPoint) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data) as Data
        let x = Int(normalized.x * Double(image.width))
        let y = Int(normalized.y * Double(image.height))
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 3)])
    }
}
