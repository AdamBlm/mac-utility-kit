import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import UtilityCore

struct PDFCompressionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_QPDF_TEST"] != nil))
    func losslessShrinksAndPreservesPageOrderSearchableTextAndLinks() async throws {
        let qpdf = try Self.qpdf()
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.linkedPDF(in: directory, count: 6)
        let expanded = directory.appending(path: "Expanded.pdf")
        try Self.run(qpdf, ["--qdf", "--object-streams=disable", source.path, expanded.path])
        var options = PDFCompressionOptions()
        options.qpdfExecutable = qpdf
        let sample = try await PDFCompression.sample(expanded, options: options)
        #expect(sample.samplePages == 3 && sample.totalPages == 6)
        #expect(sample.preview != nil && sample.estimatedBytes > 0)
        let output = directory.appending(path: "Compressed.pdf")
        let summary = try await PDFCompression.export(expanded, to: output, options: options) { _ in }
        #expect(summary.contains("smaller"))
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 6)
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            #expect(page.string?.contains("Searchable page \(index + 1)") == true)
            #expect(page.annotations.contains { $0.url?.absoluteString == "https://example.test/page/\(index + 1)" })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_QPDF_TEST"] != nil))
    func measuresRealCandidateAndCopiesOriginalWhenCompressionDoesNotSaveSpace() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "Minimal.pdf")
        let original = Self.minimalPDF()
        try original.write(to: source)
        var options = PDFCompressionOptions()
        options.qpdfExecutable = try Self.qpdf()
        options.preset = .balanced
        let sample = try await PDFCompression.sample(source, options: options)
        #expect(sample.samplePages == 1 && sample.estimatedBytes == sample.candidateBytes)
        #expect(sample.candidateBytes >= sample.originalBytes)
        let retained = directory.appending(path: "Kept.pdf")
        let summary = try await PDFCompression.export(source, to: retained, options: options) { _ in }
        #expect(summary.contains("Original kept"))
        #expect(try Data(contentsOf: retained) == original)

        options.keepsOriginalIfLarger = false
        let compressed = directory.appending(path: "Candidate.pdf")
        _ = try await PDFCompression.export(source, to: compressed, options: options) { _ in }
        #expect(try Data(contentsOf: compressed).count >= original.count)
        #expect(PDFDocument(url: compressed)?.pageCount == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_GHOSTSCRIPT_TEST"] != nil))
    func downsamplingRetainsSelectableTextAndPreservesPageGeometry() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.linkedPDF(in: directory, count: 1, links: false, raster: true)
        var options = PDFCompressionOptions()
        options.engine = .ghostscript
        options.ghostscriptExecutable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_GHOSTSCRIPT_TEST"]))
        options.preset = .smaller
        options.imageDPI = 96
        options.keepsOriginalIfLarger = false
        let output = directory.appending(path: "Ghostscript.pdf")
        _ = try await PDFCompression.export(source, to: output, options: options) { _ in }
        let document = try #require(PDFDocument(url: output))
        #expect(document.page(at: 0)?.string?.contains("Searchable page 1") == true)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 240, height: 160))
        let sourceImages = try Self.imageWidths(source)
        let resultImages = try Self.imageWidths(output)
        #expect(sourceImages.contains(1080))
        #expect(resultImages.contains { $0 < 300 })
    }

    @Test func refusesInvalidConfigurationWithoutAFile() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = PDFCompressionOptions()
        options.imageQuality = 0
        let source = directory.appending(path: "Source.pdf")
        let output = directory.appending(path: "Wrong.pdf")
        try Self.minimalPDF().write(to: source)
        await #expect(throws: ToolError.self) {
            try await PDFCompression.export(source, to: output, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private static func linkedPDF(in directory: URL, count: Int, links: Bool = true, raster: Bool = false) throws -> URL {
        let raw = directory.appending(path: "Raw.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 240, height: 160)
        let canvas = try #require(CGContext(raw as CFURL, mediaBox: &bounds, nil))
        let image = raster ? try Self.sampleRaster() : nil
        for index in 0..<count {
            canvas.beginPDFPage(nil)
            if let image { canvas.draw(image, in: CGRect(x: 14, y: 4, width: 144, height: 72)) }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Searchable page \(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            ]))
            canvas.textPosition = CGPoint(x: 14, y: 94)
            CTLineDraw(line, canvas)
            canvas.endPDFPage()
        }
        canvas.closePDF()
        guard links else { return raw }
        let document = try #require(PDFDocument(url: raw))
        for index in 0..<count {
            let page = try #require(document.page(at: index))
            let link = PDFAnnotation(bounds: CGRect(x: 14, y: 89, width: 105, height: 20), forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.test/page/\(index + 1)")
            page.addAnnotation(link)
        }
        let output = directory.appending(path: "Source.pdf")
        try #require(document.write(to: output))
        return output
    }

    private static func sampleRaster() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1080, height: 540, bitsPerComponent: 8, bytesPerRow: 4320,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for stripe in 0..<32 {
            context.setFillColor(CGColor(srgbRed: CGFloat(stripe) / 31, green: CGFloat(stripe % 7) / 6,
                                         blue: CGFloat(stripe % 3) / 2, alpha: 1))
            context.fill(CGRect(x: CGFloat(stripe) * 1080 / 32, y: 0, width: 35, height: 540))
        }
        return try #require(context.makeImage())
    }

    private static func imageWidths(_ url: URL) throws -> [Int] {
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let attributes = try #require(page.dictionary)
        var contents: CGPDFDictionaryRef?
        var images: CGPDFDictionaryRef?
        try #require(CGPDFDictionaryGetDictionary(attributes, "Resources", &contents))
        let resourceDictionary = try #require(contents)
        try #require(CGPDFDictionaryGetDictionary(resourceDictionary, "XObject", &images))
        let imageDictionary = try #require(images)
        var widths: [Int] = []
        CGPDFDictionaryApplyBlock(imageDictionary, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            var width: CGPDFInteger = 0
            if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
               String(cString: subtype) == "Image", CGPDFDictionaryGetInteger(dictionary, "Width", &width) {
                widths.append(width)
            }
            return true
        }, nil)
        return widths
    }

    private static func minimalPDF() -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] /Resources << >> >>"
        ]
        var bytes = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let xref = bytes.count
        bytes.append(contentsOf: "xref\n0 4\n0000000000 65535 f \n".utf8)
        for offset in offsets { bytes.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8) }
        bytes.append(contentsOf: "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return bytes
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static func qpdf() throws -> URL {
        URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_QPDF_TEST"]))
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}
