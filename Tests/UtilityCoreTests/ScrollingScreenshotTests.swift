import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Suite struct ScrollingScreenshotTests {
    @Test func stitchesCheckableOverlapInOriginalPixelOrder() throws {
        let original = try fixture(width: 132, height: 270)
        let first = try #require(original.cropping(to: CGRect(x: 0, y: 0, width: 132, height: 120)))
        let second = try #require(original.cropping(to: CGRect(x: 0, y: 71, width: 132, height: 120)))
        let third = try #require(original.cropping(to: CGRect(x: 0, y: 147, width: 132, height: 120)))
        let capture = try ScrollingScreenshot(first).adding(second).adding(third)
        #expect(capture.image.width == 132)
        #expect(capture.image.height == 267)
        #expect(capture.seamRows == [120, 191])

        let expected = try #require(original.cropping(to: CGRect(x: 0, y: 0, width: 132, height: 267)))
        for y in [0, 119, 120, 190, 191, 266] {
            #expect(try pixel(capture.image, y: y) == pixel(expected, y: y))
        }
    }

    @Test func rejectsDuplicatesAmbiguousOverlapAndChangingDimensions() throws {
        let original = try fixture(width: 120, height: 350)
        let first = try #require(original.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 120)))
        let unrelated = try #require(original.cropping(to: CGRect(x: 0, y: 170, width: 120, height: 120)))
        let resized = try #require(original.cropping(to: CGRect(x: 0, y: 50, width: 90, height: 120)))
        let capture = try ScrollingScreenshot(first)
        #expect(throws: ToolError.self) { try capture.adding(first) }
        #expect(throws: ToolError.self) { try capture.adding(unrelated) }
        #expect(throws: ToolError.self) { try capture.adding(resized) }
        #expect(capture.image.height == 120 && capture.seamRows.isEmpty)
    }

    @Test func trimsFixedEdgesAndEncodesOutput() throws {
        let source = try fixture(width: 132, height: 140)
        let trimmed = try ScrollingScreenshot.trim(source, top: 12, bottom: 18)
        #expect(trimmed.height == 110)
        #expect(try pixel(trimmed, y: 0) == pixel(source, y: 12))
        #expect(throws: ToolError.self) { try ScrollingScreenshot.trim(source, top: 90, bottom: 10) }

        for format in ScreenshotOutputFormat.allCases {
            let bytes = try ScreenshotImageOutput.encode(trimmed, format: format)
            let decoded = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            let type = CGImageSourceGetType(decoded) as String?
            #expect(type == (format == .png ? UTType.png.identifier : UTType.jpeg.identifier))
            let frame = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
            #expect(frame.width == trimmed.width && frame.height == trimmed.height)
        }
    }

    private func fixture(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8]()
        var seed: UInt32 = 128
        for _ in 0..<height {
            seed = 1_664_525 &* seed &+ 1_013_904_223
            let red = UInt8(truncatingIfNeeded: seed >> 24)
            let green = UInt8(truncatingIfNeeded: seed >> 16)
            let blue = UInt8(truncatingIfNeeded: seed >> 8)
            for x in 0..<width {
                pixels.append(contentsOf: [red, green ^ UInt8(truncatingIfNeeded: x), blue, 255])
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: [CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), .byteOrder32Big],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, y: Int) throws -> [UInt8] {
        let cut = try #require(image.cropping(to: CGRect(x: 30, y: y, width: 1, height: 1)))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cut, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
