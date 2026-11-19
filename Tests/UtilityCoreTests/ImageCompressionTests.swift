import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Test func imageCompressionPreviewMatchesExportAndCleansUpWhenReleased() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "camera.jpg")
    try writeCompressionFixture(to: source, format: .jpeg, withAlpha: false)
    let original = try Data(contentsOf: source)

    var options = ImageCompressionOptions()
    options.format = .jpg
    options.quality = 0.18
    var sample: ImageCompressionSample? = try await ImageCompressionSample.make(source, options: options)
    let preview = try #require(sample?.comparison)
    #expect(preview.source == source)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["camera.jpg"])

    let output = directory.appending(path: "export.jpg")
    let summary = try await ImageCompression.compress(source, to: output, options: options)
    #expect(sample?.summary == summary)
    #expect(try Data(contentsOf: preview.output) == Data(contentsOf: output))
    #expect(try Data(contentsOf: source) == original)
    sample = nil
    #expect(!FileManager.default.fileExists(atPath: preview.output.path))
}

@Test func imageCompressionMeetsMeasuredGoalAndLeavesSourceUntouched() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("camera.jpg")
    let output = directory.appendingPathComponent("export.jpg")
    try writeCompressionFixture(to: source, format: .jpeg, withAlpha: false)
    let before = try Data(contentsOf: source)

    var settings = ImageCompressionOptions()
    settings.quality = 0.95
    settings.targetKilobytes = 18
    #expect(try ImageCompression.outputExtension(source, options: settings) == "jpg")
    let summary = try await ImageCompression.compress(source, to: output, options: settings)

    #expect(summary.contains("Size goal reached"))
    #expect(summary.contains("smaller"))
    #expect(try Data(contentsOf: output).count <= 18_000)
    #expect(try Data(contentsOf: source) == before)
    let result = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(result, 0, nil))
    #expect(image.width == 256 && image.height == 192)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
}

@Test func imageCompressionPreservesAlphaAndReportsUnreachableLosslessGoal() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("transparent.png")
    let output = directory.appendingPathComponent("export.png")
    try writeCompressionFixture(to: source, format: .png, withAlpha: true)

    var settings = ImageCompressionOptions()
    settings.mode = .lossless
    settings.targetKilobytes = 1
    let summary = try await ImageCompression.compress(source, to: output, options: settings)
    #expect(summary.contains("Lossless encoding"))
    #expect(summary.contains("Size goal not reached"))
    #expect(try ImageConversion.hasTransparency(output))

    settings.mode = .lossy
    settings.format = .jpg
    let rejected = directory.appendingPathComponent("no-output.jpg")
    await #expect(throws: ToolError.self) {
        try await ImageCompression.compress(source, to: rejected, options: settings)
    }
    #expect(!FileManager.default.fileExists(atPath: rejected.path))
}

@Test(arguments: [8, 16])
func imageCompressionOnlyRejectsJPEGForNonOpaquePixels(depth: Int) async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let opaque = directory.appending(path: "opaque-rgba.png")
    let transparent = directory.appending(path: "transparent-rgba.png")
    let output = directory.appending(path: "opaque.jpg")
    let rejected = directory.appending(path: "transparent.jpg")
    try writeOpacityFixture(to: opaque, depth: depth, hasTransparentPixel: false)
    try writeOpacityFixture(to: transparent, depth: depth, hasTransparentPixel: true)
    let metadataSource = try #require(CGImageSourceCreateWithURL(opaque as CFURL, nil))
    let metadata = try #require(CGImageSourceCopyPropertiesAtIndex(metadataSource, 0, nil) as? [CFString: Any])
    #expect(metadata[kCGImagePropertyHasAlpha] as? Bool == true)
    #expect(try !ImageConversion.hasTransparency(opaque))
    #expect(try ImageConversion.hasTransparency(transparent))

    var options = ImageCompressionOptions()
    options.format = .jpg
    let settings = options
    _ = try await ImageCompression.compress(opaque, to: output, options: settings)
    let result = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    #expect(CGImageSourceGetType(result) as String? == UTType.jpeg.identifier)
    await #expect(throws: ToolError.self) {
        _ = try await ImageCompression.compress(transparent, to: rejected, options: settings)
    }
    #expect(!FileManager.default.fileExists(atPath: rejected.path))
}

@Test func imageCompressionReportsWhenFormatConversionGrows() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("camera.jpg")
    let output = directory.appendingPathComponent("export.png")
    try writeCompressionFixture(to: source, format: .jpeg, withAlpha: false)

    var settings = ImageCompressionOptions()
    settings.mode = .lossless
    settings.format = .png
    let summary = try await ImageCompression.compress(source, to: output, options: settings)
    #expect(summary.contains("larger"))
}

@Test func imageCompressionRejectsMultiplePagesInsteadOfDroppingThem() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let single = directory.appendingPathComponent("single.png")
    let source = directory.appendingPathComponent("multi.tiff")
    let output = directory.appendingPathComponent("export.tiff")
    try writeCompressionFixture(to: single, format: .png, withAlpha: true)
    let image = try #require(CGImageSourceCreateWithURL(single as CFURL, nil))
    let writer = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.tiff.identifier as CFString, 2, nil))
    CGImageDestinationAddImageFromSource(writer, image, 0, nil)
    CGImageDestinationAddImageFromSource(writer, image, 0, nil)
    try #require(CGImageDestinationFinalize(writer))
    let before = try Data(contentsOf: source)

    var settings = ImageCompressionOptions()
    settings.mode = .lossless
    let options = settings
    await #expect(throws: ToolError.self) {
        try await ImageCompression.compress(source, to: output, options: options)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try Data(contentsOf: source) == before)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"] != nil))
func imageCompressionUsesImageMagickForTransparentLosslessWebP() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"])
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("transparent.png")
    let output = directory.appendingPathComponent("export.webp")
    try writeCompressionFixture(to: source, format: .png, withAlpha: true)

    var settings = ImageCompressionOptions()
    settings.mode = .lossless
    settings.format = .webp
    settings.imageMagickExecutable = URL(fileURLWithPath: executable)
    let summary = try await ImageCompression.compress(source, to: output, options: settings)
    #expect(summary.contains("WebP"))
    #expect(summary.contains("Lossless encoding"))
    #expect(try ImageConversion.hasTransparency(output))
    // A VP8L chunk identifies the actual lossless WebP bitstream.
    #expect(try Data(contentsOf: output).range(of: Data("VP8L".utf8)) != nil)
}

private func compressionDirectory() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func writeCompressionFixture(to url: URL, format: UTType, withAlpha: Bool) throws {
    let width = 256
    let height = 192
    var random = UInt32(0x4845_5031)
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for pixel in 0..<(width * height) {
        for channel in 0..<3 {
            random = 1_664_525 &* random &+ 1_013_904_223
            pixels[pixel * 4 + channel] = UInt8(truncatingIfNeeded: random >> 24)
        }
        if withAlpha, pixel.isMultiple(of: 5) { pixels[pixel * 4 + 3] = 60 }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let bitmap = CGBitmapInfo(rawValue: (withAlpha ? CGImageAlphaInfo.last : .noneSkipLast).rawValue)
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: colorSpace, bitmapInfo: bitmap, provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent
    ))
    let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, format.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
    try #require(CGImageDestinationFinalize(writer))
}

private func writeOpacityFixture(to url: URL, depth: Int, hasTransparentPixel: Bool) throws {
    let width = 259
    let height = 257
    let count = width * height * 4
    let data: Data
    if depth == 16 {
        var pixels = [UInt16](repeating: .max, count: count)
        if hasTransparentPixel { pixels[count - 1] -= 1 }
        data = pixels.withUnsafeBytes { Data($0) }
    } else {
        var pixels = [UInt8](repeating: .max, count: count)
        if hasTransparentPixel { pixels[count - 1] -= 1 }
        data = Data(pixels)
    }
    let provider = try #require(CGDataProvider(data: data as CFData))
    var layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
    if depth == 16 { layout.insert(.byteOrder16Little) }
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: depth, bitsPerPixel: depth * 4,
        bytesPerRow: width * depth / 2, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: layout,
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
    let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, nil)
    try #require(CGImageDestinationFinalize(writer))
}

@Test func compressionComparisonKeepsFineDetailAtTheSameImagePosition() throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let center = CGPoint(x: 1, y: 0)
    for (index, component) in [CGFloat(0), CGFloat(1)].enumerated() {
        let context = try #require(CGContext(data: nil, width: 3_200, height: 32, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3_200, height: 32))
        context.setFillColor(gray: component, alpha: 1)
        context.fill(CGRect(x: 3_199, y: 24, width: 1, height: 8))
        let image = try #require(context.makeImage())
        let url = directory.appending(path: "\(index).png")
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        try #require(CGImageDestinationFinalize(writer))

        let preview = try #require(ImageComparisonPreview.load(url, detail: true))
        #expect(preview.isFullResolution && preview.image.width == 3_200)
        let fitted = try #require(ImageComparisonPreview.load(url, detail: false))
        #expect(fitted.image.width == 2_400 && !fitted.isFullResolution)
        #expect(abs(fitted.pixelsPerSample - 4.0 / 3.0) < 0.001)
        let corner = try #require(preview.region(center: center, viewport: CGSize(width: 1, height: 1)))
        let sample = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        sample.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = try #require(sample.data?.assumingMemoryBound(to: UInt8.self))
        #expect(pixels[0] == UInt8(component * 255))
    }
}
