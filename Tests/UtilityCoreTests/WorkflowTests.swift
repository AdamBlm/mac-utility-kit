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

private func writeVideoFixture(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoWidthKey: 640,
        AVVideoHeightKey: 480
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input, sourcePixelBufferAttributes: nil
    )
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(
        kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer
    ) == kCVReturnSuccess)
    let frame = try #require(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    if let bytes = CVPixelBufferGetBaseAddress(frame) {
        memset(bytes, 80, CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame))
    }
    CVPixelBufferUnlockBaseAddress(frame, [])

    for index in 0..<30 {
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
