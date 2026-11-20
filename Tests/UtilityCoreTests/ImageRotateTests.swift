import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

struct ImageRotateTests {
    @Test func cropsTheSelectedCornerAfterRotationWithMatchingPreview() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "Source.png")
        let output = directory.appending(path: "Crop.png")
        try Self.writeFixture(input, format: .png, orientation: 1)
        let original = try Data(contentsOf: input)
        var options = ImageRotateOptions()
        options.turn = .clockwise
        options.crop = ImageCropOptions()
        options.crop?.ratio = .square
        options.crop?.scale = 0.5
        options.crop?.horizontalPosition = 1
        options.crop?.verticalPosition = 0
        let preview = try ImageRotate.preview(input, options: options)
        _ = try ImageRotate.export(input, to: output, options: options)
        let (image, orientation) = try Self.read(output)
        #expect(image.width == 4 && image.height == 4 && orientation == 1)
        #expect(preview.outputWidth == 4 && preview.outputHeight == 4)
        #expect(try Self.corners(image) == [.red, .red, .red, .red])
        #expect(try Self.corners(preview.after) == Self.corners(image))
        #expect(try Data(contentsOf: input) == original)
        options.crop?.scale = .nan
        #expect(throws: ToolError.self) { try ImageRotate.preview(input, options: options) }
    }

    @Test func croppingOmitsEmbeddedSourceImageFromCustomXMP() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pixels = directory.appending(path: "Fixture.png")
        try Self.writeFixture(pixels, format: .png, orientation: 1)
        let (image, _) = try Self.read(pixels)
        let originalPreview = try Data(contentsOf: pixels).base64EncodedString()
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:custom="https://example.invalid/custom/">
        <custom:OriginalPreview>\(originalPreview)</custom:OriginalPreview>
        </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
        let metadata = try #require(CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData))
        let input = directory.appending(path: "Source.png")
        let writer = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(writer, image, metadata, nil)
        try #require(CGImageDestinationFinalize(writer))
        func retainsFullPreview(_ url: URL) throws -> Bool {
            let read = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            guard let metadata = CGImageSourceCopyMetadataAtIndex(read, 0, nil),
                  let data = CGImageMetadataCreateXMPData(metadata, nil) as Data? else { return false }
            return String(decoding: data, as: UTF8.self).contains(originalPreview)
        }
        #expect(try retainsFullPreview(input))
        var options = ImageRotateOptions()
        options.preserveMetadata = true
        let rotated = directory.appending(path: "Rotated.png")
        _ = try ImageRotate.export(input, to: rotated, options: options)
        #expect(try retainsFullPreview(rotated))
        options.crop = ImageCropOptions()
        let cropped = directory.appending(path: "Cropped.png")
        _ = try ImageRotate.export(input, to: cropped, options: options)
        #expect(try !retainsFullPreview(cropped))
    }

    @Test(arguments: ImageRotateOptions.Turn.allCases)
    func transformsPhysicalPNGCornerPixelsAndRetainsTransparency(turn: ImageRotateOptions.Turn) throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "source.png")
        try Self.writeFixture(input, format: .png, orientation: 1)
        let output = directory.appending(path: "rotated.png")
        var options = ImageRotateOptions()
        options.turn = turn
        options.flipHorizontally = true
        options.flipVertically = true
        let preview = try ImageRotate.preview(input, options: options)
        _ = try ImageRotate.export(input, to: output, options: options)
        let (encoded, orientation) = try Self.read(output)
        let expected: [Corner] = switch turn {
        case .none: [.clear, .blue, .green, .red]
        case .clockwise: [.green, .clear, .red, .blue]
        case .half: [.red, .green, .blue, .clear]
        case .counterclockwise: [.blue, .red, .clear, .green]
        }
        #expect(orientation == 1)
        #expect(encoded.width == (turn.swapsAxes ? 8 : 12))
        #expect(encoded.height == (turn.swapsAxes ? 12 : 8))
        #expect(try Self.corners(preview.before) == [.red, .green, .blue, .clear])
        #expect(try Self.corners(preview.after) == expected)
        #expect(try Self.corners(encoded) == expected)
    }

    @Test func normalizesTaggedSourceBeforeEditsAndPreservesHeightsAndMetadata() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "source.tiff")
        try Self.writeFixture(input, format: .tiff, orientation: 6)
        #expect(try Self.read(input).1 == 6)
        let output = directory.appending(path: "rotated.tiff")
        var options = ImageRotateOptions()
        options.turn = .clockwise
        options.flipHorizontally = true
        let pair = try ImageRotate.preview(input, options: options)
        _ = try ImageRotate.export(input, to: output, options: options)
        let (encoded, orientation) = try Self.read(output)
        #expect(orientation == 1)
        #expect(pair.sourceWidth == 8 && pair.sourceHeight == 12)
        #expect(pair.outputWidth == 12 && pair.outputHeight == 8)
        #expect(try Self.corners(pair.before) == [.blue, .red, .clear, .green])
        #expect(try Self.corners(pair.after) == [.blue, .clear, .red, .green])
        #expect(try Self.corners(encoded) == [.blue, .clear, .red, .green])
        let metadata = try Self.metadata(output)
        #expect(metadata == "Camera fixture")
    }

    @Test func retainsSixteenBitPixelsInTIFF() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "16-bit.tiff")
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 20, height: 12, bitsPerComponent: 16,
                                             bytesPerRow: 160, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.251, green: 0.572, blue: 0.322, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 12))
        let raster = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, raster, nil)
        try #require(CGImageDestinationFinalize(writer))
        try #require(try Self.read(input).0.bitsPerComponent == 16)
        let output = directory.appending(path: "16-bit-rotated.tiff")
        var options = ImageRotateOptions()
        options.turn = .clockwise
        _ = try ImageRotate.export(input, to: output, options: options)
        let (encoded, orientation) = try Self.read(output)
        #expect(encoded.width == 12 && encoded.height == 20)
        #expect(encoded.bitsPerComponent == 16)
        #expect(orientation == 1)
    }

    @Test func rejectsMultiPageImagesWithoutPublishing() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "multipage.tiff")
        try Self.writeFixture(input, format: .tiff, orientation: 1, pages: 2)
        let output = directory.appending(path: "missing.tiff")
        #expect(throws: ToolError.self) { try ImageRotate.export(input, to: output, options: ImageRotateOptions()) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(arguments: [UTType.png, UTType.tiff])
    func keepsOpaqueGrayscaleProfileAndPixelValues(format: UTType) throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ext = try #require(format.preferredFilenameExtension)
        let input = directory.appending(path: "source." + ext)
        let output = directory.appending(path: "rotated." + ext)
        let space = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let flags = CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let source = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 16,
                                            bytesPerRow: 0, space: space, bitmapInfo: flags))
        let values = try #require(source.data?.assumingMemoryBound(to: UInt16.self))
        let stride = source.bytesPerRow / MemoryLayout<UInt16>.stride
        for y in 0..<2 {
            for x in 0..<3 {
                values[y * stride + x] = UInt16(10_000 + 37 * (3 * y + x))
            }
        }
        let fixture = try #require(source.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(input as CFURL, format.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, fixture, nil)
        try #require(CGImageDestinationFinalize(writer))
        let original = try Self.read(input).0
        #expect(original.colorSpace?.model == .monochrome)

        var options = ImageRotateOptions()
        options.turn = .clockwise
        _ = try ImageRotate.export(input, to: output, options: options)
        let (rotated, orientation) = try Self.read(output)
        #expect(orientation == 1)
        #expect(rotated.width == 2 && rotated.height == 3)
        #expect(rotated.bitsPerComponent == 16)
        #expect(rotated.colorSpace?.model == .monochrome)
        #expect(rotated.colorSpace?.name == original.colorSpace?.name)
        let read = try #require(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 16,
                                          bytesPerRow: 0, space: space, bitmapInfo: flags))
        read.draw(rotated, in: CGRect(x: 0, y: 0, width: 2, height: 3))
        let rotatedValues = try #require(read.data?.assumingMemoryBound(to: UInt16.self))
        let readStride = read.bytesPerRow / MemoryLayout<UInt16>.stride
        let samples = (0..<3).flatMap { row in
            [rotatedValues[row * readStride], rotatedValues[row * readStride + 1]]
        }
        #expect(samples == [10_111, 10_000, 10_148, 10_037, 10_185, 10_074])
    }

    @Test(arguments: [UTType.jpeg, UTType.heic])
    func keepsOriginalLossyContainerAndNormalizesOrientation(format: UTType) throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ext = try #require(format.preferredFilenameExtension)
        let input = directory.appending(path: "source." + ext)
        try Self.writeFixture(input, format: format, orientation: 6)
        var options = ImageRotateOptions()
        options.turn = .clockwise
        let output = directory.appending(path: "transformed." + (try ImageRotate.outputExtension(input, options: options)))
        let pair = try ImageRotate.preview(input, options: options)
        _ = try ImageRotate.export(input, to: output, options: options)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == format.identifier)
        let (decoded, orientation) = try Self.read(output)
        #expect(orientation == 1)
        #expect(decoded.width == pair.outputWidth && decoded.height == pair.outputHeight)
    }

    private enum Corner: Equatable {
        case red, green, blue, clear, other
    }

    private static func corners(_ image: CGImage) throws -> [Corner] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return [(1, 1), (image.width - 2, 1), (1, image.height - 2), (image.width - 2, image.height - 2)].map { x, y in
            let offset = bytes.advanced(by: y * context.bytesPerRow + x * 4)
            if offset[3] < 5 { return .clear }
            if offset[0] > 220 && offset[1] < 20 && offset[2] < 20 { return .red }
            if offset[1] > 220 && offset[0] < 20 && offset[2] < 20 { return .green }
            if offset[2] > 220 && offset[0] < 20 && offset[1] < 20 { return .blue }
            return .other
        }
    }

    @Test func rotationPreviewUsesActualImageTypeAndSharesExportFormatRules() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renamedJPEG = directory.appending(path: "Renamed.png")
        try Self.writeFixture(renamedJPEG, format: .jpeg, orientation: 1)
        var options = ImageRotateOptions()
        #expect(try ImageRotate.preview(renamedJPEG, options: options).format == .jpg)
        #expect(try ImageRotate.outputExtension(renamedJPEG, options: options) == "jpg")

        let gif = directory.appending(path: "Single.gif")
        try Self.writeFixture(gif, format: .gif, orientation: 1)
        #expect(throws: ToolError.self) { try ImageRotate.preview(gif, options: options) }
        #expect(throws: ToolError.self) { try ImageRotate.outputExtension(gif, options: options) }
        options.output = .png
        #expect(try ImageRotate.preview(gif, options: options).format == .png)
        let output = directory.appending(path: "Converted.png")
        _ = try ImageRotate.export(gif, to: output, options: options)
        let written = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(written) as String? == UTType.png.identifier)
    }

    private static func writeFixture(_ url: URL, format: UTType, orientation: Int, pages: Int = 1) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 48, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (x, y, color) in [(0, 4, CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                              (6, 4, CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
                              (0, 0, CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))] {
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: y, width: 6, height: 4))
        }
        let image = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, format.identifier as CFString, pages, nil))
        for _ in 0..<pages {
            CGImageDestinationAddImage(writer, image, [
                kCGImagePropertyOrientation: orientation,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "Camera fixture"]
            ] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(writer))
    }

    private static func read(_ url: URL) throws -> (CGImage, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), properties[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    private static func metadata(_ url: URL) throws -> String? {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFImageDescription] as? String
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
