import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import UtilityCore

struct DocumentScannerTests {
    @Test func correctsSkewRotatesAndExportsTwoPages() async throws {
        let input = try imageData()
        var page = try #require(DocumentScanner.load(input, name: "Fixture").first)
        page.corners = ScanCorners(
            topLeft: CGPoint(x: 0.1, y: 0.85), topRight: CGPoint(x: 0.91, y: 0.95),
            bottomRight: CGPoint(x: 0.88, y: 0.12), bottomLeft: CGPoint(x: 0.2, y: 0.08)
        )
        page.color = .grayscale
        let corrected = try DocumentScanner.corrected(page)
        #expect(corrected.width > corrected.height)
        var rotated = page
        rotated.rotation = 1
        let rendered = try DocumentScanner.corrected(rotated)
        #expect(rendered.width == corrected.height)
        #expect(rendered.height == corrected.width)

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "Scan.pdf")
        try await DocumentScanner.export([page, rotated], to: output, paper: .a4) { _ in }
        let pdf = try #require(CGPDFDocument(output as CFURL))
        #expect(pdf.numberOfPages == 2)
        #expect(try DocumentScanner.load(Data(contentsOf: output), name: "Camera scan").count == 2)
        await #expect(throws: ToolError.self) {
            try await DocumentScanner.export([page], to: output, paper: .letter) { _ in }
        }
        try await DocumentScanner.export([page], to: output, paper: .letter, replacingConfirmedOutput: true) { _ in }
        #expect(CGPDFDocument(output as CFURL)?.numberOfPages == 1)
    }

    @Test func rejectsCrossedCornerHandles() throws {
        var page = try #require(DocumentScanner.load(try imageData(), name: "Fixture").first)
        page.corners = .fullPage
        page.corners.topLeft = CGPoint(x: 0.9, y: 0.1)
        #expect(!page.corners.isValid)
        #expect(throws: ToolError.self) { try DocumentScanner.corrected(page) }
    }

    @Test func retainsDetectedCornersAcrossManualEdits() throws {
        let source = try #require(DocumentScanner.load(try imageData(), name: "Fixture").first)
        let detected = ScanCorners(
            topLeft: CGPoint(x: 0.1, y: 0.85), topRight: CGPoint(x: 0.91, y: 0.95),
            bottomRight: CGPoint(x: 0.88, y: 0.12), bottomLeft: CGPoint(x: 0.2, y: 0.08)
        )
        var page = ScannedPage(name: source.name, image: source.image, corners: detected)
        let initial = try DocumentScanner.corrected(page)
        page.corners = .fullPage
        #expect(try DocumentScanner.corrected(page).width == source.image.width)
        #expect(page.detectedCorners == detected)
        page.corners = page.detectedCorners
        let restored = try DocumentScanner.corrected(page)
        #expect(restored.width == initial.width && restored.height == initial.height)
        #expect(restored.width != source.image.width)
    }

    @Test func boundedFileImportRejectsOversizedAndNonlocalSources() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appending(path: "scan.png")
        try imageData().write(to: image)
        #expect(try DocumentScanner.load(image).count == 1)
        #expect(throws: ToolError.self) { try DocumentScanner.load(directory) }
        let remote = try #require(URL(string: "file://other-machine.invalid/scan.png"))
        #expect(throws: ToolError.self) { try DocumentScanner.load(remote) }

        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: UInt64(DocumentScanner.inputLimit + 1))
        try handle.close()
        #expect(throws: ToolError.self) { try DocumentScanner.load(image) }
    }

    @Test func importsRotatedCroppedPDFAlongsideAnImageAndExportsInOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appending(path: "base.pdf")
        var media = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(base as CFURL, mediaBox: &media, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 30, y: 40, width: 60, height: 40))
            context.endPDFPage()
        }
        context.closePDF()

        let document = try #require(PDFDocument(url: base))
        let rotated = try #require(document.page(at: 1))
        rotated.rotation = 90
        rotated.setBounds(CGRect(x: 10, y: 20, width: 120, height: 260), for: .cropBox)
        let sourcePDF = folder.appending(path: "source.pdf")
        try #require(document.write(to: sourcePDF))
        let image = folder.appending(path: "scan.png")
        try imageData().write(to: image)

        let pages = try [sourcePDF, image].flatMap { try DocumentScanner.load($0) }
        #expect(pages.map(\.name) == ["source.pdf · 1", "source.pdf · 2", "scan.png"])
        #expect(pages.map { CGSize(width: $0.image.width, height: $0.image.height) }
            == [CGSize(width: 600, height: 900), CGSize(width: 780, height: 360), CGSize(width: 180, height: 100)])
        let output = folder.appending(path: "assembled.pdf")
        try await DocumentScanner.export(pages, to: output, paper: .original) { _ in }
        let assembled = try #require(CGPDFDocument(output as CFURL))
        #expect(assembled.numberOfPages == 3)
        let boxes = (1...3).compactMap { assembled.page(at: $0)?.getBoxRect(.mediaBox).size }
        #expect(boxes.count == 3)
        #expect(boxes.map { $0.width > $0.height } == [false, true, true])
    }

    @Test func importsEveryTIFFPageBeforeTheNextFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appending(path: "next.png")
        let tiff = folder.appending(path: "scan.tiff")
        let data = try imageData()
        try data.write(to: png)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let second = try #require(first.cropping(to: CGRect(x: 0, y: 0, width: 60, height: 80)))
        let writer = try #require(CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(writer, first, nil)
        CGImageDestinationAddImage(writer, second, nil)
        try #require(CGImageDestinationFinalize(writer))

        let pages = try [tiff, png].flatMap { try DocumentScanner.load($0) }
        #expect(pages.map(\.name) == ["scan.tiff · 1", "scan.tiff · 2", "next.png"])
        #expect(pages.map { $0.image.width } == [180, 60, 180])
    }

    private func imageData() throws -> Data {
        let canvas = try #require(CGContext(data: nil, width: 180, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(red: 0.85, green: 0.72, blue: 0.2, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: 180, height: 100))
        canvas.setFillColor(gray: 0.1, alpha: 1)
        for index in 0..<5 {
            canvas.fill(CGRect(x: 30, y: 18 + index * 13, width: 120, height: 4))
        }
        let image = try #require(canvas.makeImage())
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        try #require(CGImageDestinationFinalize(writer))
        return data as Data
    }
}
