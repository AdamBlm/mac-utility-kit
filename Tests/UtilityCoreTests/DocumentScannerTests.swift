import CoreGraphics
import Foundation
import ImageIO
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
