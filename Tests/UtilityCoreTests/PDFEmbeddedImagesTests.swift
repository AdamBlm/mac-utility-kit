import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import UtilityCore

struct PDFEmbeddedImagesTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_QPDF_TEST"] != nil))
    func targetsBothResolutionsAndKeepsRealTransparency() async throws {
        let qpdf = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_QPDF_TEST"]))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "Source.pdf")
        try Self.fixture().write(to: source)

        var options = PDFCompressionOptions.recommended
        options.qpdfExecutable = qpdf
        for (preset, width) in [(PDFCompressionOptions.Preset.balanced, 300), (.smaller, 192)] {
            options.preset = preset
            let output = directory.appending(path: preset.rawValue + ".pdf")
            let summary = try await PDFCompression.export(source, to: output, options: options) { _ in }
            #expect(summary.contains("embedded images"))
            let document = try #require(PDFDocument(url: output))
            #expect(document.pageCount == 1)
            #expect(document.page(at: 0)?.string?.contains("Searchable text") == true)
            #expect(document.outlineRoot?.child(at: 0)?.label == "Image fixture")
            #expect(document.page(at: 0)?.annotations.first?.url?.absoluteString == "https://example.test/")
            let page = try #require(document.page(at: 0)?.pageRef)
            let opaque = try #require(PDFImagePlacements.image(named: "/Opaque", on: page))
            let transparent = try #require(PDFImagePlacements.image(named: "/Transparent", on: page))
            let opaqueDictionary = try #require(CGPDFStreamGetDictionary(opaque))
            let transparentDictionary = try #require(CGPDFStreamGetDictionary(transparent))
            var measured: CGPDFInteger = 0
            var mask: CGPDFStreamRef?
            #expect(CGPDFDictionaryGetInteger(opaqueDictionary, "Width", &measured) && measured == width)
            #expect(!CGPDFDictionaryGetStream(opaqueDictionary, "SMask", &mask))
            #expect(CGPDFDictionaryGetInteger(transparentDictionary, "Width", &measured) && measured == 720)
            try #require(CGPDFDictionaryGetStream(transparentDictionary, "SMask", &mask))
            let maskStream = try #require(mask)
            var format = CGPDFDataFormat.raw
            let alpha = try #require(CGPDFStreamCopyData(maskStream, &format)) as Data
            #expect(format == .raw && alpha.count == 720 * 360)
            #expect(alpha.first == 0 && alpha.dropFirst().allSatisfy { $0 == 255 })
        }
    }

    private static func fixture() -> Data {
        func stream(_ dictionary: String, _ bytes: Data) -> Data {
            Data("<< \(dictionary) /Length \(bytes.count) >>\nstream\n".utf8) + bytes + Data("\nendstream".utf8)
        }
        let width = 720
        let height = 360
        let pixels = Data((0..<(width * height * 3)).map { UInt8(truncatingIfNeeded: ($0 / 17) ^ ($0 / 512)) })
        let alpha = Data(repeating: 255, count: width * height)
        var realAlpha = alpha
        realAlpha[0] = 0
        let image = "/Type /XObject /Subtype /Image /BitsPerComponent 8 /Width \(width) /Height \(height)"
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 260] /Contents 4 0 R /Annots [13 0 R] /Resources << /XObject << /Opaque 5 0 R /Transparent 7 0 R >> /Font << /F1 9 0 R >> >> >>".utf8),
            stream("", Data("q 72 0 0 36 0 0 cm /Opaque Do Q q 144 0 0 72 0 45 cm /Opaque Do Q q 144 0 0 72 0 125 cm /Transparent Do Q BT /F1 12 Tf 10 220 Td (Searchable text) Tj ET".utf8)),
            stream(image + " /ColorSpace /DeviceRGB /SMask 6 0 R", pixels),
            stream(image + " /ColorSpace /DeviceGray", alpha),
            stream(image + " /ColorSpace /DeviceRGB /SMask 8 0 R", pixels),
            stream(image + " /ColorSpace /DeviceGray", realAlpha),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            Data("<< /Type /Outlines /First 11 0 R /Last 11 0 R /Count 1 >>".utf8),
            Data("<< /Parent 10 0 R /Title (Image fixture) /Dest [3 0 R /Fit] >>".utf8),
            Data("null".utf8),
            Data("<< /Type /Annot /Subtype /Link /Rect [10 220 90 238] /A << /S /URI /URI (https://example.test/) >> >>".utf8)
        ]
        var result = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n".utf8))
            result.append(object)
            result.append(Data("\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }
}
