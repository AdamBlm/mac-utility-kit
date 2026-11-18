import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Suite struct BeautifyScreenshotTests {
    @Test func fitsEntireImageOnVerticalCanvas() throws {
        var options = BeautifyScreenshotOptions()
        options.aspect = .vertical
        options.longestEdge = 960
        options.padding = 40
        let source = CGSize(width: 800, height: 200)
        let layout = try BeautifyScreenshot.layout(sourceSize: source, options: options)
        #expect(layout.width == 540)
        #expect(layout.height == 960)
        #expect(abs(layout.fittedContent.width - 460) < 0.001)
        #expect(abs(layout.fittedContent.height - 115) < 0.001)
        #expect(layout.fittedContent.midX == 270)
        #expect(layout.fittedContent.midY == 480)
        options.padding = 300
        #expect(throws: ToolError.self) { try BeautifyScreenshot.layout(sourceSize: source, options: options) }
    }

    @Test func exportsTransparentPaddedPNGWithRoundedCorners() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try sourceImage(in: directory)
        var options = BeautifyScreenshotOptions()
        options.aspect = .square
        options.longestEdge = 240
        options.padding = 32
        options.radius = 28
        options.shadowOpacity = 0
        options.background = .transparent

        let preview = try await BeautifyScreenshot.preview(source, options: options)
        #expect(preview.width == 240 && preview.height == 240)
        #expect(try pixel(preview, x: 0, y: 0)[3] == 0)
        #expect(try pixel(preview, x: 32, y: 76)[3] == 0)
        #expect(try pixel(preview, x: 120, y: 120)[3] == 255)

        let output = directory.appendingPathComponent("styled.png")
        _ = try await BeautifyScreenshot.export(source, to: output, options: options) { _ in }
        let reader = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        #expect(try pixel(result, x: 0, y: 0)[3] == 0)
        #expect(try pixel(result, x: 120, y: 120) == pixel(preview, x: 120, y: 120))

        options.shadowOpacity = 0.65
        options.shadowBlur = 14
        let withShadow = try await BeautifyScreenshot.preview(source, options: options)
        let nearTop = try pixel(withShadow, x: 120, y: 71)[3]
        let nearBottom = try pixel(withShadow, x: 120, y: 169)[3]
        #expect(max(nearTop, nearBottom) > 0)
        #expect(max(nearTop, nearBottom) < 255)
        #expect(try pixel(withShadow, x: 0, y: 0)[3] == 0)
    }

    @Test func respectsOrientationAndComposesGradientJPEG() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try sourceImage(in: directory, orientation: 6)
        var options = BeautifyScreenshotOptions()
        options.longestEdge = 320
        options.padding = 20
        options.background = .gradient
        options.firstColor = 0xFF0000
        options.secondColor = 0x0000FF
        options.gradientAngle = 0
        options.shadowOpacity = 0
        options.format = .jpeg
        let output = directory.appendingPathComponent("styled.jpg")
        _ = try await BeautifyScreenshot.export(source, to: output, options: options) { _ in }
        let reader = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        #expect(result.width == 160 && result.height == 320)
        let left = try pixel(result, x: 1, y: 10)
        let right = try pixel(result, x: 158, y: 10)
        #expect(left[0] > left[2])
        #expect(right[2] > right[0])
        let preview = try await BeautifyScreenshot.preview(source, options: options)
        #expect(try pixel(preview, x: 1, y: 10) == left)
        options.background = .transparent
        await #expect(throws: ToolError.self) { try await BeautifyScreenshot.preview(source, options: options) }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func sourceImage(in folder: URL, orientation: Int = 1) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        let url = folder.appendingPathComponent("original.jpg")
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
        return url
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = Array(repeating: UInt8(0), count: 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try #require(CGContext(data: memory.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
