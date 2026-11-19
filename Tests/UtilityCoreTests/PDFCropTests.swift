import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import UtilityCore

struct PDFCropTests {
    @Test func cropsSelectedRotatedPageAndPreservesOtherPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = directory.appendingPathComponent("base.pdf")
        let input = directory.appendingPathComponent("input.pdf")
        let output = directory.appendingPathComponent("output.pdf")
        var media = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(base as CFURL, mediaBox: &media, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 25, y: 40, width: 35, height: 45))
            context.endPDFPage()
        }
        context.closePDF()
        let source = try #require(PDFDocument(url: base))
        let second = try #require(source.page(at: 1))
        second.rotation = 90
        second.setBounds(CGRect(x: 10, y: 20, width: 170, height: 250), for: .cropBox)
        try #require(source.write(to: input))

        var options = PDFCropOptions()
        options.pages = "2"
        options.offsets.top = 5
        options.offsets.right = 15
        options.offsets.bottom = 25
        options.offsets.left = 35
        _ = try await PDFCrop.export(input, to: output, options: options) { _ in }

        let result = try #require(PDFDocument(url: output))
        let firstPage = try #require(result.page(at: 0)?.pageRef)
        let secondPage = try #require(result.page(at: 1)?.pageRef)
        #expect(result.pageCount == 2)
        #expect(firstPage.getBoxRect(.cropBox) == media)
        #expect(secondPage.rotationAngle == 90)
        #expect(secondPage.getBoxRect(.cropBox) == CGRect(x: 15, y: 55, width: 140, height: 200))
    }

    @Test(arguments: [false, true])
    func rejectsSourceReplacementBeforePublication(replaceDuringExport: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let input = folder.appending(path: "source.pdf")
        let replacement = folder.appending(path: "replacement.pdf")
        let output = folder.appending(path: "cropped.pdf")
        for (file, width) in [(input, 200.0), (replacement, 210.0)] {
            var bounds = CGRect(x: 0, y: 0, width: width, height: 300)
            let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
            context.endPDFPage()
            context.closePDF()
        }

        var options = PDFCropOptions()
        options.sourceStamp = try PDFSourceStamp.read(input)
        options.offsets.left = 10
        if !replaceDuringExport {
            _ = try FileManager.default.replaceItemAt(input, withItemAt: replacement)
        }

        await #expect(throws: ToolError.self) {
            _ = try await PDFCrop.export(input, to: output, options: options) { progress in
                if replaceDuringExport, progress == 0.5 {
                    do {
                        _ = try FileManager.default.replaceItemAt(input, withItemAt: replacement)
                    } catch {
                        Issue.record("Could not replace the source PDF: \(error)")
                    }
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try PDFSourceStamp.read(input) != options.sourceStamp)
    }

    @Test func rejectsOffsetsThatConsumeThePage() {
        var offsets = PDFCropOffsets()
        offsets.left = 101
        #expect(throws: ToolError.self) {
            try offsets.displayedBounds(in: CGSize(width: 100, height: 200))
        }
    }
}
