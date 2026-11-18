import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import UtilityCore

struct PDFMergePlanTests {
    @Test func mixedSixPagePlanInterleavesPDFsAndImageThroughRunner() async throws {
        let stage = try directory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let a = stage.appending(path: "A.pdf")
        let b = stage.appending(path: "B.pdf")
        let png = stage.appending(path: "Image.png")
        try pdf([110, 111, 112, 140, 150, 160], to: a)
        try pdf([210, 220], to: b, password: "secret")
        try image(png)

        let inputs = [a, b, png]
        var options = ToolOptions()
        options.pageRanges = ["1, 4–6", "2", ""]
        options.pdfPasswords = ["", "incorrect"]
        options.pdfOutputName = "Picked"
        options.pdfMergeOrder = [
            page(0, 0), page(2, 0), page(0, 3), page(1, 1), page(0, 5), page(0, 4)
        ]
        let originalSelection = options.pageRanges
        await #expect(throws: ToolError.self) {
            _ = try await ToolRunner.run(.mergePDFs, inputs: inputs, destination: stage, imageSize: 0, options: options) { _ in }
        }
        #expect(options.pageRanges == originalSelection)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).sorted() == ["A.pdf", "B.pdf", "Image.png"])

        options.pdfPasswords[1] = "secret"
        let result = try await ToolRunner.run(.mergePDFs, inputs: inputs, destination: stage, imageSize: 0, options: options) { _ in }
        let output = try #require(result.outputs.first)
        let document = try #require(PDFDocument(url: output))
        #expect(output.lastPathComponent == "Picked.pdf")
        #expect(document.pageCount == 6)
        let imageWidth = try #require(PDFOperations.open(png, password: "").page(at: 0)).bounds(for: .mediaBox).width
        let widths = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).width }
        #expect(widths == [110, imageWidth, 140, 220, 160, 150])
    }

    @Test func invalidEmptyMismatchedPlansFailAndSelectionReconciles() async throws {
        let stage = try directory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let input = stage.appending(path: "Source.pdf")
        try pdf([110, 120], to: input)
        #expect(throws: ToolError.self) { try PDFMergePlan.selectedPages(counts: [-1], ranges: ["all"]) }
        for range in ["0", "4", "a", "none"] {
            var options = ToolOptions()
            options.pageRanges = [range]
            await #expect(throws: ToolError.self) {
                _ = try await ToolRunner.run(.mergePDFs, inputs: [input], destination: stage, imageSize: 0, options: options) { _ in }
            }
        }
        var options = ToolOptions()
        options.pdfMergeOrder = [page(0, 0), page(0, 0)]
        await #expect(throws: ToolError.self) {
            _ = try await ToolRunner.run(.mergePDFs, inputs: [input], destination: stage, imageSize: 0, options: options) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path) == ["Source.pdf"])
        #expect(PDFMergePlan.reconcile(selected: [page(0, 0), page(1, 1), page(2, 0)],
                                       custom: [page(1, 1), page(1, 1), page(1, 0), page(0, 0)])
                == [page(1, 1), page(0, 0), page(2, 0)])
    }

    @Test func samePageCountReplacementRequiresRefreshingTheSourceStamp() async throws {
        let stage = try directory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = stage.appending(path: "Source.pdf")
        let alias = stage.appending(path: "Alias.pdf")
        let replacement = stage.appending(path: "Replacement.pdf")
        try pdf([110], to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        var options = ToolOptions()
        options.pdfMergeOrder = [page(0, 0)]
        options.pdfMergeSourceStamps = try [0: PDFMergeSourceStamp.read(alias)]
        try pdf([210], to: replacement)
        _ = try FileManager.default.replaceItemAt(source, withItemAt: replacement)
        do {
            _ = try await ToolRunner.run(.mergePDFs, inputs: [alias], destination: stage, imageSize: 0, options: options) { _ in }
            Issue.record("A reviewed file was replaced before merge.")
        } catch {
            #expect(error.localizedDescription.contains("Refresh the source previews"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).sorted() == ["Alias.pdf", "Source.pdf"])

        options.pdfMergeSourceStamps = try [0: PDFMergeSourceStamp.read(alias)]
        let merged = try await ToolRunner.run(.mergePDFs, inputs: [alias], destination: stage, imageSize: 0, options: options) { _ in }
        let output = try #require(merged.outputs.first)
        #expect(PDFDocument(url: output)?.page(at: 0)?.bounds(for: .mediaBox).width == 210)
    }

    private func page(_ source: Int, _ index: Int) -> PDFMergePageReference { .init(source: source, page: index) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func pdf(_ widths: [Int], to url: URL, password: String? = nil) throws {
        let options = password.map { [kCGPDFContextUserPassword: $0, kCGPDFContextOwnerPassword: "owner"] }
        let context = try #require(CGContext(url as CFURL, mediaBox: nil, options as CFDictionary?))
        for width in widths {
            var bounds = CGRect(x: 0, y: 0, width: width, height: 100)
            let bytes = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: bytes] as CFDictionary)
            context.fill(bounds)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func image(_ url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 78, height: 59, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.fill(CGRect(x: 0, y: 0, width: 78, height: 59))
        let raster = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, raster, nil)
        try #require(CGImageDestinationFinalize(writer))
    }
}
