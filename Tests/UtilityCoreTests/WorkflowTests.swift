import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Test func resizeBatchKeepsOriginalAndReportsInvalidInput() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let valid = try imageFixture(in: folder)
    let broken = try [1, 3].map { index in
        let parent = folder.appendingPathComponent("Folder \(index)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let file = parent.appendingPathComponent(valid.lastPathComponent)
        try Data().write(to: file)
        return file
    }
    let original = try Data(contentsOf: valid)
    let report = try await ToolRunner.run(
        .resizeImages, inputs: [broken[0], valid, broken[1]], destination: folder, imageSize: 40
    ) { fraction in
        guard fraction == 2.0 / 3.0 else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            let staging = try #require(files.first { $0.hasPrefix(".MacUtilityKit-") })
            let path = folder.appendingPathComponent(staging).path
            let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o700)
        } catch {
            Issue.record("Could not check the batch staging permissions: \(error)")
        }
    }

    #expect(report.failures.count == 2)
    #expect(report.failures.first?.hasPrefix("1 - \(valid.lastPathComponent) — ") == true)
    #expect(report.failures.last?.hasPrefix("3 - \(valid.lastPathComponent) — ") == true)
    #expect(report.outputs.count == 1)
    #expect(report.outputs.first?.lastPathComponent == "2 - \(valid.lastPathComponent)")
    let output = try #require(report.outputs.first)
    let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 40)
    #expect(image.height == 20)
    #expect(try Data(contentsOf: valid) == original)
}

@Test func resizePreviewRejectsAnExecutableDirectory() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try imageFixture(in: folder)
    var options = ToolOptions()
    options.imageMagickExecutable = folder
    let error = #expect(throws: ToolError.self) {
        try ToolRunner.imagePreview(source, longestEdge: 40, options: options)
    }
    #expect(error?.localizedDescription.contains("Choose an executable ImageMagick binary") == true)
    options.imageMagickExecutable = nil
    #expect(try ToolRunner.imagePreview(source, longestEdge: 40, options: options) == "40 × 20")
}

@Test func resizeBatchShortensLongGeneratedFilenames() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = try imageFixture(in: folder)
    let original = try Data(contentsOf: image)
    let commonStem = String(repeating: "é", count: 82)
    let inputs = try ["first", "other"].map { ending in
        let url = folder.appendingPathComponent(commonStem + ending + ".png")
        try original.write(to: url)
        return url
    }

    let report = try await ToolRunner.run(
        .resizeImages, inputs: inputs, destination: folder, imageSize: 40
    ) { _ in }
    #expect(report.failures.isEmpty)
    #expect(report.outputs.map(\.lastPathComponent) == ["1 - " + commonStem + "f.png", "2 - " + commonStem + "o.png"])
    for input in inputs { #expect(try Data(contentsOf: input) == original) }
}

@Test(arguments: [0.5, 1.0])
func cancelingResizeBatchDiscardsStagedOutputs(cancelAt: Double) async throws {
    let folder = try temporaryFolder()
    let manager = FileManager.default
    defer { try? manager.removeItem(at: folder) }
    let first = try imageFixture(in: folder)
    let second = folder.appendingPathComponent("second.png")
    try manager.copyItem(at: first, to: second)
    let original = try Data(contentsOf: first)

    let job = Task {
        try await ToolRunner.run(.resizeImages, inputs: [first, second], destination: folder, imageSize: 40) { progress in
            guard progress >= cancelAt else { return }
            let manager = FileManager.default
            let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let stage = entries?.first { $0.lastPathComponent.hasPrefix(".MacUtilityKit-") }
            let stagedFiles = stage.flatMap { try? manager.contentsOfDirectory(atPath: $0.path) }
            #expect(stagedFiles?.count == Int(cancelAt * 2))
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    await #expect(throws: CancellationError.self) { try await job.value }
    #expect(Set(try manager.contentsOfDirectory(atPath: folder.path)) == [first.lastPathComponent, second.lastPathComponent])
    #expect(try Data(contentsOf: first) == original)
    #expect(try Data(contentsOf: second) == original)
}

@Test func mergeWritesReadablePDF() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = try imageFixture(in: folder)
    let report = try await ToolRunner.run(
        .mergePDFs, inputs: [image, image], destination: folder, imageSize: 0
    ) { _ in }
    let output = try #require(report.outputs.first)
    let pdf = try #require(PDFDocument(url: output))
    #expect(pdf.pageCount == 2)
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func imageFixture(in folder: URL, width: Int = 100, height: Int = 50) throws -> URL {
    let url = folder.appendingPathComponent("sample.png")
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let writer = try #require(CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(writer, image, nil)
    try #require(CGImageDestinationFinalize(writer))
    return url
}

@Test func blurFacesPublishesOnlyReviewedSourcesThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reviewed = try imageFixture(in: folder)
    let unreviewed = folder.appendingPathComponent("unreviewed.png")
    try FileManager.default.copyItem(at: reviewed, to: unreviewed)
    var options = ToolOptions()
    let source = try ImageRedaction.load(reviewed)
    options.blurFaces.regions[reviewed] = [ImageMaskRegion(rect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))]
    options.blurFaces.confirmReview(reviewed, source: source)
    let report = try await ToolRunner.run(
        .blurFaces, inputs: [reviewed, unreviewed], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.hasPrefix("unreviewed.png") == true)
    #expect(report.outputs.count == 1)
    let output = try #require(report.outputs.first)
    #expect(output.pathExtension == "png")
    #expect(CGImageSourceCreateWithURL(output as CFURL, nil) != nil)
    #expect(try Data(contentsOf: reviewed) == Data(contentsOf: unreviewed))
}

@Test func redactImagePublishesFlattenedCopyThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try imageFixture(in: folder)
    let original = try Data(contentsOf: input)
    let source = try ImageRedaction.load(input)
    var options = ToolOptions()
    var masks = ImageRedactEdit()
    masks.regions = [ImageMaskRegion(rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5))]
    options.redactImage.apply(masks, to: input, source: source)
    let report = try await ToolRunner.run(
        .redactImage, inputs: [input], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    let decoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    #expect(CGImageSourceGetCount(decoded) == 1)
    #expect(try Data(contentsOf: output) != original)
    #expect(try Data(contentsOf: input) == original)
}

@Test func watermarkPublishesAnImageCopyThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try imageFixture(in: folder)
    let original = try Data(contentsOf: input)
    var options = ToolOptions()
    options.watermark.text = "Review"
    options.watermark.placement = .center
    let report = try await ToolRunner.run(
        .watermark, inputs: [input], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    let decoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(image.width == 100 && image.height == 50)
    #expect(try Data(contentsOf: output) != original)
    #expect(try Data(contentsOf: input) == original)
}

@Test func compressWritesSmallerPlayableMP4() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source)
    let report = try await ToolRunner.run(
        .compressVideo, inputs: [source], destination: folder, imageSize: 0
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    let asset = AVURLAsset(url: output)
    #expect(try await asset.load(.isPlayable))
    let sourceSize = try #require(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let outputSize = try #require(output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(outputSize < sourceSize)
}

private func writeVideoFixture(
    to url: URL, width: Int = 640, height: Int = 480, frames: Int = 30,
    transform: CGAffineTransform = .identity, patterned: Bool = false
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input, sourcePixelBufferAttributes: nil
    )
    input.transform = transform
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
    ) == kCVReturnSuccess)
    let frame = try #require(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    if let bytes = CVPixelBufferGetBaseAddress(frame) {
        memset(bytes, 80, CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame))
        if patterned {
            var seed: UInt32 = 0xabcdef01
            let stride = CVPixelBufferGetBytesPerRow(frame)
            for row in 0..<height {
                for column in 0..<width {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let color = 0xff00_0000 | (seed >> 8)
                    bytes.storeBytes(of: color, toByteOffset: row * stride + column * 4, as: UInt32.self)
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(frame, [])

    for index in 0..<frames {
        try await waitForFixtureVideoInput(input, writer: writer)
        try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishMediaWriting()
    try #require(writer.status == .completed)
}

@Test func pageRangesPreserveUserOrderAndRejectInvalidPages() throws {
    let selected = [4, 0, 1, 2, 3]
    let expression = PageSelection.expression(for: selected)
    #expect(expression == "5, 1–4")
    #expect(try PageSelection.indices(expression, pageCount: 5) == selected)
    #expect(PageSelection.expression(for: []) == "none")
    #expect(try PageSelection.indices("5, 1, 3–4, 1", pageCount: 5) == [4, 0, 2, 3])
    #expect(try PageSelection.indices("5,\n1–3", pageCount: 5) == [4, 0, 1, 2])
    #expect(try PageSelection.indices("none", pageCount: 5).isEmpty)
    #expect(try PageSelection.indices("all", pageCount: 0).isEmpty)
    #expect(throws: ToolError.self) { try PageSelection.indices("all", pageCount: -1) }
    let emptyDocument = #expect(throws: ToolError.self) { try PageSelection.indices("1", pageCount: 0) }
    #expect(emptyDocument?.localizedDescription == "The document has no pages.")
    #expect(throws: ToolError.self) { try PageSelection.indices("6", pageCount: 5) }
    #expect(throws: ToolError.self) { try PageSelection.indices("4-2", pageCount: 5) }
}

@Test func mergeAppliesSelectionPerSource() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("first.pdf")
    let second = folder.appendingPathComponent("second.pdf")
    try writePDF(widths: [100, 150, 200], to: first)
    try writePDF(widths: [300, 400], to: second)
    var options = ToolOptions()
    options.pageRanges = ["3, 1", "2"]
    let invalidNames = [
        ("Bad\u{0}Name", "Enter a valid PDF filename."),
        (String(repeating: "é", count: 84), "The PDF filename is too long. Enter a shorter name.")
    ]
    for (invalidName, expectedMessage) in invalidNames {
        options.pdfOutputName = invalidName
        let error = await #expect(throws: ToolError.self) {
            try await ToolRunner.run(.mergePDFs, inputs: [first, second], destination: folder, imageSize: 0, options: options) { _ in }
        }
        #expect(error?.localizedDescription == expectedMessage)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["first.pdf", "second.pdf"])
    options.pdfOutputName = "Chosen"
    let report = try await ToolRunner.run(
        .mergePDFs, inputs: [first, second], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let output = try #require(report.outputs.first)
    let pdf = try #require(PDFDocument(url: output))
    #expect(output.lastPathComponent == "Chosen.pdf")
    #expect(pdf.pageCount == 3)
    let widths = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox).width }
    #expect(widths == [200, 100, 400])
}

private func writePDF(widths: [Int], to url: URL) throws {
    let context = try #require(CGContext(url as CFURL, mediaBox: nil, nil))
    for width in widths {
        var box = CGRect(x: 0, y: 0, width: width, height: 100)
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
        context.fill(box)
        context.endPDFPage()
    }
    context.closePDF()
}

@Test func nativeResizePreservesDisplayP3ColorAndAlpha() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appending(path: "wide-gamut.png")
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let layout = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try #require(CGContext(data: nil, width: 48, height: 24, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space, bitmapInfo: layout))
    let green = try #require(CGColor(colorSpace: space, components: [0, 1, 0, 1]))
    context.setFillColor(green)
    context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
    let image = try #require(context.makeImage())
    let writer = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, nil)
    try #require(CGImageDestinationFinalize(writer))

    var options = ToolOptions()
    options.imageSizing = .percentage
    options.imagePercentage = 50
    options.imageFormat = .png
    let report = try await ToolRunner.run(
        .resizeImages, inputs: [input], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let output = try #require(report.outputs.first)
    let decoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let resized = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(resized.width == 24 && resized.height == 12)
    #expect(resized.colorSpace?.model == .rgb)

    func sample(_ x: Int) throws -> [UInt8] {
        let pixel = try #require(resized.cropping(to: CGRect(x: x, y: 5, width: 1, height: 1)))
        let buffer = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: space, bitmapInfo: layout))
        buffer.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: try #require(buffer.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }

    let opaque = try sample(4)
    #expect(opaque[0] < 4 && opaque[1] > 250 && opaque[2] < 4 && opaque[3] == 255)
    #expect(try sample(20)[3] == 0)
}

@Test func exactImageFillMatchesPreviewAndSelectedFormat() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try imageFixture(in: folder)
    var options = ToolOptions()
    options.imageSizing = .dimensions
    options.imageFit = .fill
    options.imageWidth = 30
    options.imageHeight = 30
    options.imageFormat = .jpg
    #expect(try ToolRunner.imagePreview(source, longestEdge: 0, options: options) == "30 × 30")
    let report = try await ToolRunner.run(
        .resizeImages, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let output = try #require(report.outputs.first)
    let decoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(output.pathExtension == "jpg")
    #expect(image.width == 30 && image.height == 30)
}

@Test func resizeThinImageKeepsAtLeastOnePixelInPreviewAndExport() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try imageFixture(in: folder, width: 100, height: 1)
    var options = ToolOptions()
    options.imageSizing = .percentage
    options.imagePercentage = 20
    options.imageFormat = .png
    #expect(try ToolRunner.imagePreview(source, longestEdge: 0, options: options) == "20 × 1")
    let report = try await ToolRunner.run(
        .resizeImages, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let output = try #require(report.outputs.first, "\(report.failures)")
    let decoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(image.width == 20 && image.height == 1)
}

@Test(arguments: ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"] == nil ? [false] : [false, true])
func resizeImageRejectsMultiplePagesAndPublishesOrientedStill(useImageMagick: Bool) async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let still = folder.appending(path: "still.tiff")
    let multi = folder.appending(path: "multiple.tiff")
    let image = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
    for (destination, count) in [(still, 1), (multi, 2)] {
        let writer = try #require(CGImageDestinationCreateWithURL(destination as CFURL, UTType.tiff.identifier as CFString, count, nil))
        for _ in 0..<count {
            CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(writer))
    }
    let firstBytes = try Data(contentsOf: still)
    let multiBytes = try Data(contentsOf: multi)
    var settings = ToolOptions()
    settings.imageSizing = .percentage
    settings.imagePercentage = 50
    settings.imageFormat = .png
    if useImageMagick {
        let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"])
        settings.imageMagickExecutable = URL(fileURLWithPath: executable)
    }

    #expect(try ToolRunner.imagePreview(still, longestEdge: 0, options: settings) == "8 × 16")
    let previewError = #expect(throws: ToolError.self) {
        try ToolRunner.imagePreview(multi, longestEdge: 0, options: settings)
    }
    #expect(previewError?.localizedDescription.contains("single frame or page") == true)
    let report = try await ToolRunner.run(.resizeImages, inputs: [multi, still], destination: folder,
                                          imageSize: 0, options: settings) { _ in }
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.contains("single frame or page") == true)
    #expect(report.outputs.count == 1)
    let output = try #require(report.outputs.first)
    let decoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let raster = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(raster.width == 8 && raster.height == 16)
    #expect(CGImageSourceGetType(decoded) as String? == UTType.png.identifier)
    #expect(try Data(contentsOf: still) == firstBytes)
    #expect(try Data(contentsOf: multi) == multiBytes)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"] != nil))
func resizeBatchDiscardsAReplacedImageAndContinuesWithTheNextFile() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try imageFixture(in: folder)
    let first = folder.appending(path: "input.png")
    let replacement = folder.appending(path: "replacement.png")
    for file in [first, replacement] { try FileManager.default.copyItem(at: source, to: file) }
    let original = try Data(contentsOf: source)
    var options = ToolOptions()
    options.imageMagickExecutable = try imageMagickWithSourceReplacement(in: folder)
    let report = try await ToolRunner.run(.resizeImages, inputs: [first, source], destination: folder,
                                          imageSize: 40, options: options) { _ in }
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.contains("input.png — The source image changed") == true)
    #expect(report.outputs.map(\.lastPathComponent) == ["2 - " + source.lastPathComponent])
    let published = try #require(report.outputs.first)
    let decoded = try #require(CGImageSourceCreateWithURL(published as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(image.width == 40 && image.height == 20)
    #expect(try Data(contentsOf: source) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: published.deletingLastPathComponent().path)
            == [published.lastPathComponent])
}

@Test func videoSampleAndExportUseSelectedFormat() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source)
    var options = ToolOptions()
    options.videoFormat = .mov
    options.videoQuality = .smaller
    options.keepLargerVideos = true
    let sample = try await ToolRunner.sampleVideo(source, destination: folder, options: options)
    #expect(sample.url.pathExtension == "mov")
    #expect(sample.estimatedBytes != nil)
    let report = try await ToolRunner.run(
        .compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let output = try #require(report.outputs.first)
    #expect(output.pathExtension == "mov")
    #expect(try await AVURLAsset(url: output).load(.isPlayable))
    #expect(report.summaries.count == 1)
}

@Test func frameExtractionPublishesNestedOutputsWithMixedBatchResults() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source)
    let missing = folder.appendingPathComponent("missing.mov")
    var options = ToolOptions()
    options.frames.timestamps = [0, 0.25]
    let report = try await ToolRunner.run(
        .extractFrames, inputs: [missing, source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.hasPrefix("missing.mov") == true)
    #expect(report.outputs.count == 2)
    for output in report.outputs {
        #expect(output.deletingLastPathComponent().lastPathComponent == "2 - source")
        #expect(CGImageSourceCreateWithURL(output as CFURL, nil) != nil)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(!names.contains { $0.hasPrefix(".MacUtilityKit-") })
}

@Test func trimAndMutePublishThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source)

    var options = ToolOptions()
    options.trim.start = 0.15
    options.trim.end = 0.65
    let trimmed = try await ToolRunner.run(
        .trimVideo, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(trimmed.failures.isEmpty)
    let output = try #require(trimmed.outputs.first)
    #expect(output.pathExtension == "mp4")
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    #expect(abs(duration - 0.5) < 0.075)

    let silent = try await ToolRunner.run(
        .muteVideo, inputs: [output], destination: folder, imageSize: 0
    ) { _ in }
    #expect(silent.outputs.isEmpty)
    #expect(silent.failures.count == 1)
    #expect(FileManager.default.fileExists(atPath: source.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(!names.contains { $0.hasPrefix(".MacUtilityKit-") })
}

@Test(arguments: [false, true])
func trimVideoUsesEachPreviewedRangeInAMixedDurationBatch(replaceShort: Bool) async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let long = folder.appending(path: "long.mov")
    let short = folder.appending(path: "short.mov")
    try await writeVideoFixture(to: long, width: 160, height: 120, frames: 30)
    try await writeVideoFixture(to: short, width: 160, height: 120, frames: 18)
    let inputs = [long, short]
    var options = ToolOptions()
    options.trim.start = 0.2
    let longRange = try await TrimVideo.plannedRange(long, options: options.trim)
    let shortRange = try await TrimVideo.plannedRange(short, options: options.trim)
    #expect(longRange.end > shortRange.end)
    options.trimSourceVersions = try [0: LocalInputFile.Version.read(long), 1: LocalInputFile.Version.read(short)]
    if replaceShort {
        let sameBytes = try Data(contentsOf: short)
        try sameBytes.write(to: short, options: .atomic)
    }
    let report = try await ToolRunner.run(.trimVideo, inputs: inputs, destination: folder, imageSize: 0, options: options) { _ in }
    if replaceShort {
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("short.mov — The video changed after the trim preview") == true)
    } else {
        #expect(report.failures.isEmpty)
    }
    #expect(report.outputs.count == (replaceShort ? 1 : 2))
    for (output, planned) in zip(report.outputs, [longRange, shortRange]) {
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        #expect(abs(try await asset.load(.duration).seconds - planned.duration) < 0.075)
    }
}

@Test func resizeVideoPublishesAlignedMP4ThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source)
    let rotated = try await VideoResizeTests.makePortraitVideo(in: folder)
    var options = ToolOptions()
    options.videoResize.sizing = .percentage
    options.videoResize.percentage = 50
    let inputs = [source, rotated]
    let dimensions = [CGSize(width: 320, height: 240), CGSize(width: 32, height: 64)]
    for (file, expected) in zip(inputs, dimensions) {
        let size = try await VideoResize.sourceSize(file)
        let layout = try VideoResizeLayout.plan(sourceSize: size, options: options.videoResize)
        #expect(CGSize(width: layout.width, height: layout.height) == expected)
        let framing = try await VideoResize.preview(file, options: options.videoResize)
        #expect(CGSize(width: framing.width, height: framing.height) == expected)
    }
    let report = try await ToolRunner.run(
        .resizeVideo, inputs: inputs, destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    #expect(report.outputs.count == inputs.count)
    for (output, expected) in zip(report.outputs, dimensions) {
        #expect(output.pathExtension == "mp4")
        let report = try await MediaInspection.inspect(output)
        #expect(report.summary.contains("Dimensions: \(Int(expected.width)) × \(Int(expected.height))"))
    }
    #expect(inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}

@Test func mergeVideosPublishesOneOutputAndRejectsABrokenSequence() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("first.mov")
    let second = folder.appendingPathComponent("second.mov")
    try await writeVideoFixture(to: first, frames: 12)
    try await writeVideoFixture(to: second, width: 320, height: 240, frames: 18)
    let report = try await ToolRunner.run(
        .mergeVideos, inputs: [first, second], destination: folder, imageSize: 0
    ) { _ in }
    #expect(report.failures.isEmpty)
    #expect(report.outputs.count == 1)
    let output = try #require(report.outputs.first)
    let asset = AVURLAsset(url: output)
    #expect(try await asset.load(.isPlayable))
    let expected = try await VideoMerge.plan([first, second], options: VideoMergeOptions()).duration
    #expect(abs(try await asset.load(.duration).seconds - expected) < 0.075)

    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    let missing = folder.appendingPathComponent("missing.mov")
    await #expect(throws: (any Error).self) {
        try await ToolRunner.run(.mergeVideos, inputs: [first, missing], destination: folder, imageSize: 0) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names)
}

@Test func mergeVideosRejectsAClipReplacedBeforeItReadsTheSequence() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appending(path: "first.mov")
    let second = folder.appending(path: "second.mov")
    let replacement = folder.appending(path: "replacement.mov")
    for clip in [first, second, replacement] { try await writeVideoFixture(to: clip, frames: 8) }
    let output = folder.appending(path: "output.mov")
    await #expect {
        try await VideoMerge.export([first, second], to: output, options: VideoMergeOptions()) { progress in
            if progress == 0 {
                do { _ = try FileManager.default.replaceItemAt(second, withItemAt: replacement) }
                catch { Issue.record("Could not replace the video fixture: \(error)") }
            }
        }
    } throws: { error in
        error.localizedDescription == "second.mov changed during merging. Try again."
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["first.mov", "second.mov"])
}

@Test func replaceAudioPublishesPlayableSoundtrackThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source)
    let audio = folder.appendingPathComponent("replacement.wav")
    try writeToneFixture(to: audio)
    var options = ToolOptions()
    options.replaceAudio.source = audio
    let report = try await ToolRunner.run(
        .replaceAudio, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    let asset = AVURLAsset(url: output)
    #expect(try await asset.load(.isPlayable))
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: audio.path))
}

private func writeToneFixture(to audio: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let frames = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    frames.frameLength = frames.frameCapacity
    let samples = try #require(frames.floatChannelData?[0])
    for index in 0..<Int(frames.frameLength) {
        samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.25
    }
    do {
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        try file.write(from: frames)
    }
}

@Test func trimAudioPublishesTheRequestedSampleRangeThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.wav")
    try writeToneFixture(to: source)
    var options = ToolOptions()
    options.audioTrim.start = 0.125
    options.audioTrim.end = 0.625
    let report = try await ToolRunner.run(
        .trimAudio, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    let track = try AudioTrim.source(output)
    #expect(track.sampleRate == 48_000)
    #expect(track.frameCount == 24_000)
    #expect(try AudioTrim.source(source).frameCount == 48_000)
}

@Test func convertAudioPublishesSelectedFormatAndSampleRateThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.wav")
    try writeToneFixture(to: source)
    var options = ToolOptions()
    options.audioConvert.format = .aiff
    options.audioConvert.sampleRate = 32_000
    options.audioConvert.channels = .stereo
    let report = try await ToolRunner.run(
        .convertAudio, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    #expect(output.pathExtension == "aiff")
    let result = try AVAudioFile(forReading: output)
    #expect(result.fileFormat.channelCount == 2)
    #expect(result.fileFormat.sampleRate == 32_000)
    #expect(result.length == 32_000)
    #expect(try AudioTrim.source(source).frameCount == 48_000)
}

@Test func balancedKeepsEachSourceResolutionInMixedBatchAnd4KSample() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("4k.mov")
    let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
    try await writeVideoFixture(to: source, width: 3840, height: 2160, frames: 8, transform: rotation)

    let landscape = folder.appendingPathComponent("1080p.mov")
    try await writeVideoFixture(to: landscape, width: 1920, height: 1080, frames: 8)

    let options = ToolOptions()
    let report = try await ToolRunner.run(
        .compressVideo, inputs: [source, landscape], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    try #require(report.outputs.count == 2)
    #expect(report.outputs.map { $0.deletingPathExtension().lastPathComponent } == ["1 - 4k", "2 - 1080p"])
    let landscapeAsset = AVURLAsset(url: report.outputs[1])
    let landscapeTrack = try #require(try await landscapeAsset.loadTracks(withMediaType: .video).first)
    #expect(try await landscapeTrack.load(.naturalSize) == CGSize(width: 1920, height: 1080))
    #expect(try await landscapeTrack.load(.preferredTransform) == .identity)
    let export = report.outputs[0]
    let sample = try await ToolRunner.sampleVideo(source, destination: folder, options: options)

    for url in [export, sample.url] {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 3840, height: 2160))
        #expect(try await track.load(.preferredTransform) == rotation)
    }
}

@Test func balancedSupportsM4VContainer() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source, frames: 8)
    var options = ToolOptions()
    options.videoFormat = .m4v
    let report = try await ToolRunner.run(
        .compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    #expect(output.pathExtension == "m4v")
    #expect(try await AVURLAsset(url: output).load(.isPlayable))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func ffmpegConstantQualityKeeps4KAndOrientation() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("4k.mov")
    let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
    try await writeVideoFixture(to: source, width: 3840, height: 2160, frames: 8, transform: rotation)

    var options = ToolOptions()
    options.ffmpegExecutable = URL(fileURLWithPath: executable)
    for codec in [VideoCodec.automatic, .hevc] {
        options.videoCodec = codec
        let result = try await ToolRunner.run(
            .compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options
        ) { _ in }
        #expect(result.failures.isEmpty)
        let export = try #require(result.outputs.first)
        let sample = try await ToolRunner.sampleVideo(source, destination: folder, options: options)
        for url in [export, sample.url] {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            let track = try #require(tracks.first)
            #expect(try await track.load(.naturalSize) == CGSize(width: 3840, height: 2160))
            #expect(try await track.load(.preferredTransform) == rotation)
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"] != nil))
func imageMagickFillMatchesDimensionsAndPreservesInput() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try imageFixture(in: folder)
    let original = try Data(contentsOf: source)
    var options = ToolOptions()
    options.imageMagickExecutable = URL(fileURLWithPath: executable)
    options.imageSizing = .dimensions
    options.imageFit = .fill
    options.imageWidth = 30
    options.imageHeight = 30
    let report = try await ToolRunner.run(
        .resizeImages, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    let decoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(image.width == 30 && image.height == 30)
    #expect(try Data(contentsOf: source) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path) == [output.lastPathComponent])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"] != nil),
      arguments: [Tool.resizeImages, .convertImages])
func imageMagickBatchPublishesOnlyVerifiedOutputs(tool: Tool) async throws {
    let manager = FileManager.default
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_MAGICK_TEST"])
    let folder = try temporaryFolder()
    defer { try? manager.removeItem(at: folder) }
    let realEngine = folder.appending(path: "real-magick")
    try manager.createSymbolicLink(at: realEngine, withDestinationURL: URL(filePath: executable))
    let wrapper = folder.appending(path: "magick-wrapper")
    try Data(#"""
    #!/bin/sh
    engine_dir=$(dirname "$0")
    count=$(cat "$engine_dir/count" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$engine_dir/count"
    printf '%s\n' diagnostic > engine-diagnostics.txt
    "$engine_dir/real-magick" "$@" || exit $?
    if [ "$count" -eq 2 ]; then
        echo 'export failed after writing' >&2
        exit 1
    fi
    """#.utf8).write(to: wrapper)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let source = try imageFixture(in: folder)
    let failing = folder.appending(path: "fail.png")
    let last = folder.appending(path: "last.png")
    for copy in [failing, last] { try manager.copyItem(at: source, to: copy) }
    let original = try Data(contentsOf: source)

    var options = ToolOptions()
    options.imageMagickExecutable = wrapper
    options.imageConversion.format = .webp
    options.imageConversion.imageMagickExecutable = wrapper
    let report = try await ToolRunner.run(
        tool, inputs: [source, failing, last], destination: folder, imageSize: 40, options: options
    ) { _ in }

    #expect(report.failures == ["fail.png — export failed after writing"])
    #expect(report.outputs.count == 2)
    let firstOutput = try #require(report.outputs.first)
    let published = try manager.contentsOfDirectory(atPath: firstOutput.deletingLastPathComponent().path)
    #expect(Set(published) == Set(report.outputs.map(\.lastPathComponent)))
    for input in [source, failing, last] { #expect(try Data(contentsOf: input) == original) }
}

@Test func mediaInfoPublishesJSONAndPreservesOtherBatchResultsOnBadInput() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let valid = folder.appendingPathComponent("source.mov")
    let other = folder.appending(path: "Other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let duplicate = other.appending(path: valid.lastPathComponent)
    let invalid = folder.appendingPathComponent("broken.mov")
    try await writeVideoFixture(to: valid, frames: 8)
    try FileManager.default.copyItem(at: valid, to: duplicate)
    try Data("No media".utf8).write(to: invalid)
    let report = try await ToolRunner.run(
        .mediaInfo, inputs: [valid, invalid, duplicate], destination: folder, imageSize: 0
    ) { _ in }
    #expect(report.failures.count == 1)
    #expect(report.outputs.count == 2)
    #expect(report.summaries.first?.hasPrefix("1 - source.mov\n") == true)
    #expect(report.inspections.map(\.filename) == ["source.mov", "source.mov"])
    #expect(report.inspections.map(\.inputLabel) == ["1 - source.mov", "3 - source.mov"])
    let output = try #require(report.outputs.first)
    #expect(output.pathExtension == "json")
    let data = try Data(contentsOf: output)
    #expect(try JSONDecoder().decode([MediaInspectionReport.Section].self, from: data).count >= 2)
    #expect(try Data(contentsOf: invalid) == Data("No media".utf8))
}

@Test func imageWavePublishesBatchResultsAndComparisonURLs() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try imageFixture(in: folder)
    let invalid = folder.appendingPathComponent("broken.png")
    try Data("Not an image".utf8).write(to: invalid)
    let original = try Data(contentsOf: source)

    var options = ToolOptions()
    options.imageConversion.format = .jpg
    let converted = try await ToolRunner.run(
        .convertImages, inputs: [source, invalid], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(converted.failures.count == 1)
    #expect(converted.outputs.map(\.pathExtension) == ["jpg"])

    let compressed = try await ToolRunner.run(
        .compressImages, inputs: [source, invalid], destination: folder, imageSize: 0
    ) { _ in }
    #expect(compressed.failures.count == 1)
    let comparison = try #require(compressed.imageComparisons.first)
    #expect(comparison.source == source)
    #expect(compressed.outputs == [comparison.output])
    #expect(FileManager.default.fileExists(atPath: comparison.output.path))
    #expect(comparison.sourceBytes == original.count)
    #expect(comparison.outputBytes == (try Data(contentsOf: comparison.output)).count)
    #expect(try Data(contentsOf: source) == original)
}

@Test func pdfEditingToolsPublishExpectedPagesAndKeepInputIntact() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("Source.pdf")
    try writePDF(widths: [100, 150, 200], to: source)
    let original = try Data(contentsOf: source)

    var options = ToolOptions()
    options.pdfSplit.mode = .everyN
    options.pdfSplit.pagesPerFile = 2
    let split = try await ToolRunner.run(
        .splitPDF, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(split.outputs.map(\.lastPathComponent) == ["Source-1.pdf", "Source-2.pdf"])
    #expect(split.outputs.compactMap { PDFDocument(url: $0)?.pageCount } == [2, 1])

    options.pdfOrganize.pages = [PDFPageEdit(pageNumber: 3, quarterTurns: 1), PDFPageEdit(pageNumber: 1)]
    let organized = try await ToolRunner.run(
        .organizePDF, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let organizedURL = try #require(organized.outputs.first)
    let organizedPDF = try #require(PDFDocument(url: organizedURL))
    #expect(organizedPDF.pageCount == 2)
    #expect(organizedPDF.page(at: 0)?.rotation == 90)

    options.pdfDelete.range = "2"
    let deleted = try await ToolRunner.run(
        .deletePDFPages, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let deletedURL = try #require(deleted.outputs.first)
    let deletedPDF = try #require(PDFDocument(url: deletedURL))
    #expect(deletedPDF.pageCount == 2)
    #expect(deletedPDF.page(at: 1)?.bounds(for: .mediaBox).width == 200)
    #expect(try Data(contentsOf: source) == original)
}

@Test func pdfConversionWavePublishesOrderedOutputsAndPreservesInputs() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let image = try imageFixture(in: folder)
    let imageBytes = try Data(contentsOf: image)
    let source = folder.appendingPathComponent("Mixed.pdf")
    try writePDF(widths: [100, 150, 200], to: source)
    let sourceBytes = try Data(contentsOf: source)

    var options = ToolOptions()
    options.pdfExtract.range = "3, 1"
    options.pdfExtract.order = .selection
    let extracted = try await ToolRunner.run(
        .extractPDFPages, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let extractedURL = try #require(extracted.outputs.first)
    let extractedDocument = try #require(PDFDocument(url: extractedURL))
    #expect(extractedDocument.pageCount == 2)
    #expect(extractedDocument.page(at: 0)?.bounds(for: .mediaBox).width == 200)

    options.imagesToPDF.paper = .original
    options.imagesToPDF.margin = 0
    let combined = try await ToolRunner.run(
        .imagesToPDF, inputs: [image, image], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let combinedURL = try #require(combined.outputs.first)
    let combinedDocument = try #require(PDFDocument(url: combinedURL))
    #expect(combinedDocument.pageCount == 2)
    #expect(combinedDocument.page(at: 0)?.bounds(for: .mediaBox).width == 100)

    options.pdfToImages.range = "3, 1"
    options.pdfToImages.resolution = .dpi
    options.pdfToImages.dpi = 72
    let converted = try await ToolRunner.run(
        .pdfToImages, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(converted.outputs.map(\.lastPathComponent) == ["Mixed-3.png", "Mixed-1.png"])
    let widths = try converted.outputs.map { output in
        let data = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(data, 0, nil)).width
    }
    #expect(widths == [200, 100])
    #expect(try Data(contentsOf: source) == sourceBytes)
    #expect(try Data(contentsOf: image) == imageBytes)
}

@Test func signingAndOCRPublishThroughTheSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("Original.pdf")
    try writePDF(widths: [200, 300], to: source)
    let sourceBytes = try Data(contentsOf: source)

    var options = ToolOptions()
    options.pdfSignature.text = "Taylor"
    options.pdfSignature.pageRange = "2"
    let signed = try await ToolRunner.run(
        .signPDF, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    let signedURL = try #require(signed.outputs.first)
    let document = try #require(PDFDocument(url: signedURL))
    #expect(document.page(at: 0)?.annotations.isEmpty == true)
    #expect(document.page(at: 1)?.annotations.contains(where: { $0.contents == "Visual signature" }) == true)
    #expect(try Data(contentsOf: source) == sourceBytes)

    let image = try imageFixture(in: folder)
    let corrupted = folder.appendingPathComponent("broken.png")
    try Data("Not an image".utf8).write(to: corrupted)
    let report = try await ToolRunner.run(
        .extractText, inputs: [image, corrupted], destination: folder, imageSize: 0
    ) { _ in }
    #expect(report.outputs.map(\.pathExtension) == ["txt"])
    #expect(report.failures.count == 1)
    #expect(report.textExtractions.first?.source == image)
    #expect(report.textExtractions.first?.result.pages.count == 1)
}

@Test func advancedNativeCompressionAppliesCapAndKeepsPortraitOrientation() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("rotated.mov")
    let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
    try await writeVideoFixture(to: source, width: 640, height: 360, frames: 16, transform: rotation)
    var options = ToolOptions()
    options.videoCompression.rateControl = .averageBitrate
    options.videoCompression.videoKbps = 750
    options.videoCompression.maximumEdge = 320
    options.videoCompression.audioKbps = 128
    let preview = try await VideoCompression.preview(source, options: options, capabilities: .macOS)
    #expect(preview.width == 180 && preview.height == 320)
    let report = try await ToolRunner.run(.compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options) { _ in }
    #expect(report.failures.isEmpty, "\(report.failures)")
    let url = try #require(report.outputs.first)
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
    #expect(try await track.load(.preferredTransform) == CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0))
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func advancedFFmpegCompressionSupportsWebMAndSourceOrientedScaling() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("rotated.mov")
    let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
    try await writeVideoFixture(to: source, width: 640, height: 360, frames: 16, transform: rotation)

    var options = ToolOptions()
    options.ffmpegExecutable = URL(fileURLWithPath: executable)
    options.videoFormat = .webm
    options.videoCompression.rateControl = .constantQuality
    options.videoCompression.quality = 31
    options.videoCompression.maximumEdge = 320
    options.keepLargerVideos = true
    let caps = try await VideoCompressionCapabilities.ffmpeg(URL(fileURLWithPath: executable))
    if !caps.supports(.webm, codec: .vp9) { return }
    #expect(!caps.supports(.webm, codec: .h264))
    let preview = try await VideoCompression.preview(source, options: options, capabilities: caps)
    #expect(preview.width == 180 && preview.height == 320 && preview.codec == .vp9)
    let report = try await ToolRunner.run(.compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options) { _ in }
    #expect(report.failures.isEmpty, "\(report.failures)")
    #expect(report.outputs.first?.pathExtension == "webm")
    let sample = try await ToolRunner.sampleVideo(source, destination: folder, options: options)
    #expect(sample.url.pathExtension == "webm")
    #expect(sample.estimatedBytes != nil)
}

@Test func advancedCompressionRejectsUnsupportedModesAndInvalidRanges() async {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
    var options = ToolOptions()
    options.videoFormat = .webm
    await #expect(throws: ToolError.self) {
        try await VideoCompression.preview(source, options: options, capabilities: .macOS)
    }
    options.videoFormat = .mp4
    options.videoCompression.rateControl = .constantQuality
    await #expect(throws: ToolError.self) {
        try await VideoCompression.preview(source, options: options, capabilities: .macOS)
    }
    options.videoCompression.rateControl = .averageBitrate
    options.videoCompression.videoKbps = 3
    await #expect(throws: ToolError.self) {
        try await VideoCompression.preview(source, options: options, capabilities: .macOS)
    }
    options.videoCompression.videoKbps = 1_000
    options.videoCompression.maximumEdge = 1
    await #expect(throws: ToolError.self) {
        try await VideoCompression.preview(source, options: options, capabilities: .macOS)
    }
    options.videoCompression.maximumEdge = nil
    options.videoCompression.audioKbps = 999
    await #expect(throws: ToolError.self) {
        try await VideoCompression.preview(source, options: options, capabilities: .macOS)
    }
}

@Test func advancedAudioBitrateChangesTheReencodedTrack() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appendingPathComponent("video.mov")
    let tone = folder.appendingPathComponent("tone.wav")
    try await writeVideoFixture(to: video, width: 320, height: 180, frames: 36)
    try writeToneFixture(to: tone)
    var mux = ToolOptions()
    mux.replaceAudio.source = tone
    let sourceReport = try await ToolRunner.run(.replaceAudio, inputs: [video], destination: folder, imageSize: 0, options: mux) { _ in }
    let source = try #require(sourceReport.outputs.first)
    var actualRates: [Float] = []
    for target in [64, 256] {
        var options = ToolOptions()
        options.videoCompression.audioKbps = target
        options.keepLargerVideos = true
        let report = try await ToolRunner.run(.compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options) { _ in }
        #expect(report.failures.isEmpty, "\(report.failures)")
        let url = try #require(report.outputs.first)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        let audio = try #require(tracks.first)
        actualRates.append(try await audio.load(.estimatedDataRate))
    }
    #expect(actualRates[0] > 0)
    #expect(actualRates[1] > actualRates[0])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func advancedConstantQualityChangesTheEncodedSize() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("pattern.mov")
    try await writeVideoFixture(to: source, width: 640, height: 360, frames: 16, patterned: true)
    var outputSizes: [Int] = []
    for quality in [14, 40] {
        var options = ToolOptions()
        options.ffmpegExecutable = URL(fileURLWithPath: executable)
        options.videoCompression.rateControl = .constantQuality
        options.videoCompression.quality = quality
        options.keepLargerVideos = true
        let report = try await ToolRunner.run(.compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options) { _ in }
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        outputSizes.append(try #require(output.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    }
    #expect(outputSizes[0] > outputSizes[1])
}

@Test func compressionFormatsExposeHEVCWhenH264IsAbsent() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("ffmpeg-mock")
    let script = """
    #!/bin/sh
    case "$3" in
      -encoders) printf ' V....D libx265 HEVC\\n A....D aac AAC\\n';;
      -muxers) printf ' E mp4 MP4\\n E mov MOV\\n';;
      *) exit 1;;
    esac
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let capabilities = try await VideoCompressionCapabilities.ffmpeg(executable)
    #expect(capabilities.formats == [.mp4, .mov, .m4v])
    #expect(capabilities.supports(.mp4, codec: .hevc))
    #expect(capabilities.supports(.mp4, codec: .automatic))

    let input = folder.appendingPathComponent("SDR.mp4")
    try await writeVideoFixture(to: input)
    var options = ToolOptions()
    options.ffmpegExecutable = executable
    let automatic = try await VideoCompression.preview(input, options: options, capabilities: capabilities)
    #expect(automatic.codec == .hevc)

    options.videoCodec = .h264
    await #expect(throws: ToolError.self) {
        _ = try await VideoCompression.preview(input, options: options, capabilities: capabilities)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func automaticHEVCFallbackMatchesPreviewSampleAndExport() async throws {
    let ffmpeg = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createSymbolicLink(at: folder.appending(path: "ffmpeg-real"), withDestinationURL: ffmpeg)
    let executable = folder.appending(path: "ffmpeg-hevc")
    let script = #"""
    #!/bin/sh
    ffmpeg="$(dirname "$0")/ffmpeg-real"
    case "$3" in
      -encoders) "$ffmpeg" "$@" | /usr/bin/awk '$2 != "libx264"';;
      *) exec "$ffmpeg" "$@";;
    esac
    """#
    try Data(script.utf8).write(to: executable, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let input = folder.appending(path: "SDR.mp4")
    try await writeVideoFixture(to: input, width: 160, height: 120, frames: 12)
    var options = ToolOptions()
    options.ffmpegExecutable = executable
    options.keepLargerVideos = true

    let capabilities = try await VideoCompressionCapabilities.ffmpeg(executable)
    #expect(!capabilities.supports(.mp4, codec: .h264))
    let preview = try await VideoCompression.preview(input, options: options, capabilities: capabilities)
    #expect(preview.codec == .hevc)
    let sample = try await ToolRunner.sampleVideo(input, destination: folder, options: options)
    let report = try await ToolRunner.run(
        .compressVideo, inputs: [input], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    for url in [sample.url, try #require(report.outputs.first)] {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func webMCompressionNormalizesAnamorphicPixelsAndSideSurround() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("anamorphic.mp4")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error",
                          "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=24",
                          "-f", "lavfi", "-i", "anullsrc=cl=5.1(side):r=48000",
                          "-t", "0.5", "-vf", "setsar=8/9", "-c:v", "libx264", "-c:a", "aac", source.path]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)

    var options = ToolOptions()
    options.ffmpegExecutable = URL(fileURLWithPath: executable)
    options.videoFormat = .webm
    options.keepLargerVideos = true
    let capabilities = try await VideoCompressionCapabilities.ffmpeg(URL(fileURLWithPath: executable))
    if !capabilities.supports(.webm, codec: .vp9) { return }
    let review = try await VideoCompression.preview(source, options: options, capabilities: capabilities)
    #expect(review.width == 640 && review.height == 480)
    let report = try await ToolRunner.run(.compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options) { _ in }
    #expect(report.failures.isEmpty, "\(report.failures)")
    let output = try #require(report.outputs.first)

    let inspect = Process()
    let log = Pipe()
    inspect.executableURL = URL(fileURLWithPath: executable)
    inspect.arguments = ["-nostdin", "-hide_banner", "-i", output.path,
                         "-map", "0:a:0", "-t", "0.1", "-f", "null", "-"]
    inspect.standardError = log
    try inspect.run()
    let info = String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    inspect.waitUntilExit()
    #expect(inspect.terminationStatus == 0)
    #expect(info.contains("Audio: opus, 48000 Hz, 5.1"))
}
