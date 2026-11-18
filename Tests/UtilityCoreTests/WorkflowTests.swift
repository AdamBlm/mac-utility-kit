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
    let invalid = folder.appendingPathComponent("invalid.png")
    try Data().write(to: invalid)
    let original = try Data(contentsOf: valid)
    let report = try await ToolRunner.run(
        .resizeImages, inputs: [valid, invalid], destination: folder, imageSize: 40
    ) { _ in }

    #expect(report.failures.count == 1)
    let output = try #require(report.outputs.first)
    let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 40)
    #expect(image.height == 20)
    #expect(try Data(contentsOf: valid) == original)
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

private func imageFixture(in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent("sample.png")
    let context = try #require(CGContext(
        data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
    let image = try #require(context.makeImage())
    let writer = try #require(CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(writer, image, nil)
    try #require(CGImageDestinationFinalize(writer))
    return url
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
    transform: CGAffineTransform = .identity
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
    }
    CVPixelBufferUnlockBaseAddress(frame, [])

    for index in 0..<frames {
        for _ in 0..<500 where !input.isReadyForMoreMediaData && writer.status == .writing {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(input.isReadyForMoreMediaData)
        try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
}

@Test func pageRangesPreserveUserOrderAndRejectInvalidPages() throws {
    #expect(try PageSelection.indices("5, 1, 3–4, 1", pageCount: 5) == [4, 0, 2, 3])
    #expect(try PageSelection.indices("none", pageCount: 5).isEmpty)
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

@Test func resizeVideoPublishesAlignedMP4ThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source)
    var options = ToolOptions()
    options.videoResize.sizing = .percentage
    options.videoResize.percentage = 50
    let report = try await ToolRunner.run(
        .resizeVideo, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let output = try #require(report.outputs.first)
    #expect(output.pathExtension == "mp4")
    let asset = AVURLAsset(url: output)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 240))
    #expect(FileManager.default.fileExists(atPath: source.path))
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

@Test func replaceAudioPublishesPlayableSoundtrackThroughSharedRunner() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.mov")
    try await writeVideoFixture(to: source)
    let audio = folder.appendingPathComponent("replacement.wav")
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

@Test func balancedKeeps4KResolutionInExportAndSample() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("4k.mov")
    let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
    try await writeVideoFixture(to: source, width: 3840, height: 2160, frames: 8, transform: rotation)

    let options = ToolOptions()
    let report = try await ToolRunner.run(
        .compressVideo, inputs: [source], destination: folder, imageSize: 0, options: options
    ) { _ in }
    #expect(report.failures.isEmpty)
    let export = try #require(report.outputs.first)
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

@Test func mediaInfoPublishesJSONAndPreservesOtherBatchResultsOnBadInput() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let valid = folder.appendingPathComponent("source.mov")
    let invalid = folder.appendingPathComponent("broken.mov")
    try await writeVideoFixture(to: valid, frames: 8)
    try Data("No media".utf8).write(to: invalid)
    let report = try await ToolRunner.run(
        .mediaInfo, inputs: [valid, invalid], destination: folder, imageSize: 0
    ) { _ in }
    #expect(report.failures.count == 1)
    #expect(report.outputs.count == 1)
    #expect(report.summaries.first?.hasPrefix("source.mov\n") == true)
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
