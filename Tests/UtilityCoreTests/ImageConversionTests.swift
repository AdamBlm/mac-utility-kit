import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Test func imageConversionAppliesOrientationAndKeepsMetadataWhenAsked() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("portrait.jpg")
    try writeConversionImage(to: source, type: .jpeg, orientation: 6)
    let original = try Data(contentsOf: source)

    var options = ImageConversionOptions()
    options.format = .jpg
    let retained = folder.appendingPathComponent("retained.jpg")
    let summary = try await ImageConversion.convert(source, to: retained, options: options)
    let retainedProps = try conversionProperties(retained)
    #expect(retainedProps[kCGImagePropertyPixelWidth] as? Int == 12)
    #expect(retainedProps[kCGImagePropertyPixelHeight] as? Int == 24)
    #expect((retainedProps[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    #expect((retainedProps[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String
            == "2023:01:02 03:04:05")
    #expect(summary.contains("12 × 24"))

    options.preserveMetadata = false
    let stripped = folder.appendingPathComponent("stripped.jpg")
    _ = try await ImageConversion.convert(source, to: stripped, options: options)
    let strippedProps = try conversionProperties(stripped)
    #expect((strippedProps[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
    #expect(try Data(contentsOf: source) == original)
}

@Test func imageConversionRetainsOrFlattensAlphaAndChecksOutputType() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("alpha.png")
    try writeConversionImage(to: source, type: .png, orientation: 1)
    #expect(try ImageConversion.hasTransparency(source))
    var options = ImageConversionOptions()

    let png = folder.appendingPathComponent("retained.png")
    _ = try await ImageConversion.convert(source, to: png, options: options)
    #expect(try ImageConversion.hasTransparency(png))
    let sourceColorSpace = try conversionImage(source).colorSpace
    let outputColorSpace = try conversionImage(png).colorSpace
    #expect(sourceColorSpace?.name == outputColorSpace?.name)

    options.format = .jpg
    options.backgroundRGB = 0xEE0000
    let jpeg = folder.appendingPathComponent("flattened.jpg")
    _ = try await ImageConversion.convert(source, to: jpeg, options: options)
    #expect(try !ImageConversion.hasTransparency(jpeg))
    let pixel = try conversionPixel(jpeg, x: 21, y: 5)
    #expect(pixel[0] > 200 && pixel[1] < 35 && pixel[2] < 35)

    for format in [ImageConversionFormat.tiff, .heic] {
        options.format = format
        options.flattenTransparency = true
        let output = folder.appendingPathComponent(format.rawValue + "." + format.rawValue)
        _ = try await ImageConversion.convert(source, to: output, options: options)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try !ImageConversion.hasTransparency(output))
    }
}

@Test func imageConversionRejectsMissingWebPEncoderAndDoesNotOverwrite() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.png")
    try writeConversionImage(to: source, type: .png, orientation: 1)
    let original = try Data(contentsOf: source)
    var options = ImageConversionOptions()
    await #expect(throws: ToolError.self) {
        try await ImageConversion.convert(source, to: source, options: options)
    }
    options.format = .webp
    let output = folder.appendingPathComponent("output.webp")
    await #expect(throws: ToolError.self) {
        try await ImageConversion.convert(source, to: output, options: options)
    }
    #expect(try Data(contentsOf: source) == original)
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"] != nil))
func imageConversionUsesImageMagickForWebPWithoutLosingAlpha() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"])
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("original.png")
    try writeConversionImage(to: source, type: .png, orientation: 1)
    let output = folder.appendingPathComponent("export.webp")
    var options = ImageConversionOptions()
    options.format = .webp
    options.losslessWebP = true
    options.imageMagickExecutable = URL(fileURLWithPath: executable)
    _ = try await ImageConversion.convert(source, to: output, options: options)
    #expect(try ImageConversion.hasTransparency(output))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["export.webp", "original.png"])
}

private func conversionFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func conversionProperties(_ url: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

private func writeConversionImage(to url: URL, type: UTType, orientation: Int) throws {
    let context = try #require(CGContext(
        data: nil, width: 24, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.1, green: 0.9, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    let image = try #require(context.makeImage())
    let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2023:01:02 03:04:05"]
    ] as CFDictionary)
    try #require(CGImageDestinationFinalize(writer))
}


private func conversionImage(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func conversionPixel(_ url: URL, x: Int, y: Int) throws -> [UInt8] {
    let image = try conversionImage(url)
    let pixel = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    let context = try #require(CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
    return [bytes[0], bytes[1], bytes[2]]
}
