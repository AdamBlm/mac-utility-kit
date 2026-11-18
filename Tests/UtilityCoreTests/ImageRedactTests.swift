import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

struct ImageRedactTests {
    @Test func undoAndRedoRestoreMaskGeometryAndEditorSettings() throws {
        try fixture { input, source, _ in
            var options = ImageRedactOptions()
            var first = options.edit(for: input)
            first.regions = [ImageMaskRegion(rect: CGRect(x: 0.2, y: 0.25, width: 0.4, height: 0.5))]
            options.apply(first, to: input, source: source)
            var changed = first
            changed.regions[0].rect.origin = CGPoint(x: 0.1, y: 0.2)
            changed.effect = .pixelate
            changed.strength = 0.4
            changed.removesMetadata = false
            options.apply(changed, to: input, source: source)
            #expect(options.canUndo(input))
            options.undo(input)
            #expect(options.edit(for: input) == first && options.canRedo(input))
            options.redo(input)
            #expect(options.edit(for: input) == changed && !options.canRedo(input))
            options.undo(input)
            var branch = first
            branch.effect = .blur
            options.apply(branch, to: input, source: source)
            #expect(options.edit(for: input) == branch && !options.canRedo(input))
        }
    }

    @Test func solidRedactionStripsOriginalMetadataByDefaultAndCanRetainSafeText() throws {
        try fixture { input, source, directory in
            var options = ImageRedactOptions()
            var edit = ImageRedactEdit()
            edit.regions = [ImageMaskRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1))]
            for preserve in [false, true] {
                edit.removesMetadata = !preserve
                options.apply(edit, to: input, source: source)
                let output = directory.appending(path: "redacted-\(preserve).png")
                _ = try ImageRedact.export(input, to: output, options: options)
                let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
                #expect(CGImageSourceGetCount(imageSource) == 1)
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
                let text = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                #expect((text?[kCGImagePropertyPNGAuthor] as? String) == (preserve ? "Fixture author" : nil))
                #expect(properties[kCGImagePropertyGPSDictionary] == nil)
                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                let generatedKeys = Set([kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension])
                #expect(Set(exif.keys).isSubset(of: generatedKeys))
                #expect(tiff[kCGImagePropertyTIFFMake] == nil)
                #expect(tiff[kCGImagePropertyTIFFModel] == nil)
                let raster = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
                let byteBuffer = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                       space: CGColorSpaceCreateDeviceRGB(),
                                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                byteBuffer.draw(raster, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                let bytes = try #require(byteBuffer.data).assumingMemoryBound(to: UInt8.self)
                #expect(Array(UnsafeBufferPointer(start: bytes, count: 4)) == [0, 0, 0, 255])
            }
        }
    }

    private func fixture(_ run: (URL, ImageRedaction.Source, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "source.tiff")
        let context = try #require(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let image = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Fixture author",
                                             kCGImagePropertyTIFFMake: "Private device maker",
                                             kCGImagePropertyTIFFModel: "Private serial model"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:18 17:01:00",
                                             kCGImagePropertyExifLensModel: "Private lens model"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8, kCGImagePropertyGPSLatitudeRef: "N",
                                           kCGImagePropertyGPSLongitude: 2.4, kCGImagePropertyGPSLongitudeRef: "E"]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
        let written = try #require(CGImageSourceCreateWithURL(input as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [CFString: Any])
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        try #require(exif[kCGImagePropertyExifDateTimeOriginal] != nil && exif[kCGImagePropertyExifLensModel] != nil)
        try #require(tiff[kCGImagePropertyTIFFMake] != nil && tiff[kCGImagePropertyTIFFModel] != nil)
        try #require(properties[kCGImagePropertyGPSDictionary] != nil)
        try run(input, ImageRedaction.load(input), directory)
    }
}
