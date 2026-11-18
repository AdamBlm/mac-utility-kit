import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

struct BlurFacesTests {
    @Test func visionBoundsFlipIntoTopLeftAndExpandWithinEdges() throws {
        let result = try #require(BlurFaces.suggestedMask(for: CGRect(x: 0.2, y: 0.7, width: 0.3, height: 0.2)))
        #expect(abs(result.rect.minX - 0.152) < 0.00001)
        #expect(abs(result.rect.minY - 0.06) < 0.00001)
        #expect(abs(result.rect.width - 0.396) < 0.00001)
        #expect(abs(result.rect.height - 0.28) < 0.00001)
        let edge = try #require(BlurFaces.suggestedMask(for: CGRect(x: 0, y: 0.9, width: 0.2, height: 0.1)))
        #expect(edge.rect.minX == 0 && edge.rect.minY == 0)
        #expect(BlurFaces.suggestedMask(for: .zero) == nil)
    }

    @Test func opaqueCoverIncludesEveryPartiallyIntersectedFullResolutionPixel() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "oriented.tiff")
        try Self.writeSource(input, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), orientation: 6)
        let source = try ImageRedaction.load(input)
        #expect(source.image.width == 12 && source.image.height == 16)
        let region = ImageMaskRegion(rect: CGRect(x: 0.24, y: 0.16, width: 0.27, height: 0.43))
        let bounds = try ImageRedaction.pixelBounds(region.rect, width: 12, height: 16)
        #expect(bounds == CGRect(x: 2, y: 2, width: 5, height: 8))

        var options = BlurFacesOptions()
        options.regions[input] = [region]
        let output = directory.appending(path: "uncovered.png")
        #expect(throws: ToolError.self) { try BlurFaces.export(input, to: output, options: options) }
        options.confirmReview(input, source: source)
        #expect(options.isReviewed(input))
        _ = try BlurFaces.export(input, to: output, options: options)
        let encoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let raster = try #require(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFImageDescription] == nil)
        let pixels = try Self.pixels(raster)
        for y in 0..<raster.height {
            for x in 0..<raster.width {
                let rgba = pixels[y * raster.width + x]
                if bounds.contains(CGPoint(x: x, y: y)) {
                    #expect(rgba == [0, 0, 0, 255])
                } else {
                    #expect(rgba == [255, 0, 0, 255])
                }
            }
        }
    }

    @Test func rejectsChangedContentAndReviewInvalidatesAfterEditing() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "source.tiff")
        let output = directory.appending(path: "should-not-exist.png")
        try Self.writeSource(input, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let loaded = try ImageRedaction.load(input)
        var options = BlurFacesOptions()
        options.regions[input] = [ImageMaskRegion(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        options.confirmReview(input, source: loaded)
        #expect(options.isReviewed(input))
        options.effect = .pixelate
        #expect(!options.isReviewed(input))
        options.confirmReview(input, source: loaded)
        try Self.writeSource(input, color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        #expect(throws: ToolError.self) { try BlurFaces.export(input, to: output, options: options) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: ToolError.self) { try ImageRedaction.pixelBounds(CGRect(x: 0.1, y: 0, width: -0.1, height: 0.2), width: 16, height: 12) }
    }

    @Test(arguments: [ImageRedactionEffect.blur, .pixelate])
    func softerEffectsApplyOnlyWithinMask(effect: ImageRedactionEffect) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for stripe in 0..<16 {
            context.setFillColor(stripe.isMultiple(of: 2) ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: stripe * 2, y: 0, width: 2, height: 32))
        }
        let original = try #require(context.makeImage())
        let region = ImageMaskRegion(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let result = try ImageRedaction.render(original, regions: [region], effect: effect, strength: 0.9)
        let before = try Self.pixels(original)
        let after = try Self.pixels(result)
        #expect(before[0] == after[0])
        #expect(before[7 * 32 + 12] == after[7 * 32 + 12])
        #expect((8..<24).contains { before[15 * 32 + $0] != after[15 * 32 + $0] })
    }

    private static func pixels(_ image: CGImage) throws -> [[UInt8]] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { index in
            Array(UnsafeBufferPointer(start: data.advanced(by: index * 4), count: 4))
        }
    }

    private static func writeSource(_ url: URL, color: CGColor, orientation: Int = 1) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let raster = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, raster, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "Private fixture"]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
