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

@Test func automaticImageCompressionKeepsAnAlreadySmallerOriginal() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "already-small.jpg")
    try writeCompressionFixture(to: source, format: .jpeg, withAlpha: false, quality: 0.08)
    let original = try Data(contentsOf: source)
    let options = ImageCompressionOptions.recommended
    let sample = try await ImageCompressionSample.make(source, options: options)
    let output = directory.appending(path: "export.jpg")
    let summary = try await ImageCompression.compress(source, to: output, options: options)
    #expect(summary.contains("Original kept"))
    #expect(sample.summary == summary)
    #expect(try Data(contentsOf: output) == original)
    #expect(try Data(contentsOf: sample.comparison.output) == original)

    var stripping = options
    stripping.preserveMetadata = false
    let stripped = directory.appending(path: "stripped.jpg")
    let strippedSummary = try await ImageCompression.compress(source, to: stripped, options: stripping)
    #expect(!strippedSummary.contains("Original kept"))
    #expect(try Data(contentsOf: stripped) != original)
}

@Test func automaticImageBatchKeepsSmallFilesAndCompressesLargerOnesIndependently() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let other = directory.appending(path: "Other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let small = directory.appending(path: "photo.jpg")
    let large = other.appending(path: "photo.jpg")
    let corrupt = directory.appending(path: "broken.jpg")
    try writeCompressionFixture(to: small, format: .jpeg, withAlpha: false, quality: 0.08)
    try writeCompressionFixture(to: large, format: .jpeg, withAlpha: false, quality: 1)
    try Data("not an image".utf8).write(to: corrupt)
    let inputs = [small, corrupt, large]
    let originals = try inputs.map { try Data(contentsOf: $0) }

    var options = ToolOptions()
    options.imageCompression = .recommended
    let report = try await ToolRunner.run(.compressImages, inputs: inputs, destination: directory,
                                          imageSize: 0, options: options) { _ in }
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.hasPrefix("2 - broken.jpg") == true)
    #expect(report.outputs.map(\.lastPathComponent) == ["1 - photo.jpg", "3 - photo.jpg"])
    #expect(report.summaries.first?.contains("Original kept") == true)
    #expect(report.summaries.last?.contains("smaller") == true)
    #expect(report.imageComparisons.map(\.source) == [small, large])
    #expect(report.imageComparisons.map(\.inputLabel) == ["1 - photo.jpg", "3 - photo.jpg"])
    let first = try #require(report.outputs.first)
    let last = try #require(report.outputs.last)
    #expect(try Data(contentsOf: first) == originals[0])
    #expect(try Data(contentsOf: last).count < originals[2].count)
    #expect(try inputs.map { try Data(contentsOf: $0) } == originals)
    let firstPair = try #require(report.imageComparisons.first)
    let secondPair = try #require(report.imageComparisons.last)
    #expect(ImageComparisonPreview.load(secondPair.source, detail: false, expected: secondPair.sourceVersion) != nil)
    try originals[2].write(to: large, options: .atomic)
    #expect(ImageComparisonPreview.load(secondPair.source, detail: true, expected: secondPair.sourceVersion) == nil)
    #expect(ImageComparisonPreview.load(firstPair.source, detail: true, expected: firstPair.sourceVersion) != nil)
    #expect(ImageComparisonPreview.load(secondPair.output, detail: true) != nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"] != nil))
func manualImageCompressionRejectsASourceReplacedDuringEncoding() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "input.png")
    let replacement = directory.appending(path: "replacement.png")
    try writeCompressionFixture(to: source, format: .png, withAlpha: false)
    let previous = try Data(contentsOf: source)
    try previous.write(to: replacement)
    let script = try imageMagickWithSourceReplacement(in: directory)
    let output = directory.appending(path: "result.webp")
    var options = ImageCompressionOptions()
    options.mode = .lossy
    options.format = .webp
    options.imageMagickExecutable = script

    await #expect {
        try await ImageCompression.compress(source, to: output, options: options)
    } throws: { error in
        error.localizedDescription.hasPrefix("The source image changed during")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() ==
            ["fixture-encoder", "input.png", "magick"])
    #expect(try Data(contentsOf: source) == previous)
}

func imageMagickWithSourceReplacement(in directory: URL) throws -> URL {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"])
    try FileManager.default.createSymbolicLink(at: directory.appending(path: "magick"),
                                               withDestinationURL: URL(filePath: executable))
    let script = directory.appending(path: "fixture-encoder")
    let shell = #"""
    #!/bin/sh
    set -eu
    root=$(/usr/bin/dirname "$0")
    "$root/magick" "$@"
    if test -f "$root/replacement.png"; then
        /bin/mv "$root/replacement.png" "$root/input.png"
    fi
    """#
    try Data(shell.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}

@Test func imageCompressionPreviewCancellationRemovesItsTemporaryDirectory() async throws {
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "camera.jpg")
    try writeCompressionFixture(to: source, format: .jpeg, withAlpha: false)
    let original = try Data(contentsOf: source)

    let preview = Task {
        try await ImageCompressionSample.make(source, options: .init(), temporaryDirectory: directory) { fraction in
            guard fraction == 1 else { return }
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            let staged = files?.allObjects.compactMap { $0 as? URL }.contains {
                $0.lastPathComponent == "1 - camera.jpg"
            }
            #expect(staged == true)
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await preview.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["camera.jpg"])
    #expect(try Data(contentsOf: source) == original)
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
func imageCompressionUsesActualMinimumWebPQualityForSizeGoal() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"])
    let folder = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appending(path: "original.png")
    try writeCompressionFixture(to: source, format: .png, withAlpha: false)

    var settings = ImageCompressionOptions()
    settings.format = .webp
    settings.imageMagickExecutable = URL(fileURLWithPath: executable)
    settings.quality = 0.01
    let minimum = folder.appending(path: "minimum.webp")
    _ = try await ImageCompression.compress(source, to: minimum, options: settings)
    let minimumData = try Data(contentsOf: minimum)

    settings.quality = 0
    let zero = folder.appending(path: "zero.webp")
    let zeroReport = try await ImageCompression.compress(source, to: zero, options: settings)
    let minimumLabel = 0.01.formatted(.percent.precision(.fractionLength(0)))
    #expect(zeroReport.contains("Quality \(minimumLabel)"))
    #expect(try Data(contentsOf: zero) == minimumData)

    let target = (minimumData.count + 999) / 1000
    settings.quality = 1
    settings.targetKilobytes = target
    let searched = folder.appending(path: "target.webp")
    let report = try await ImageCompression.compress(source, to: searched, options: settings)
    #expect(report.contains("Size goal reached"))
    #expect(try Data(contentsOf: searched).count <= target * 1000)
    let result = try #require(CGImageSourceCreateWithURL(searched as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(result, 0, nil))
    #expect(image.width == 256 && image.height == 192)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"] != nil), arguments: [ImageCompressionMode.lossless, .automatic])
func imageCompressionUsesImageMagickForTransparentLosslessWebP(_ mode: ImageCompressionMode) async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"])
    let directory = try compressionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("transparent.png")
    let output = directory.appendingPathComponent("export.webp")
    try writeCompressionFixture(to: source, format: .png, withAlpha: true)

    var settings = ImageCompressionOptions()
    settings.mode = mode
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

private func writeCompressionFixture(to url: URL, format: UTType, withAlpha: Bool, quality: Double = 0.97) throws {
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
    CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
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
