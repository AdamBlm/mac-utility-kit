import AVFoundation
import Testing
import UtilityCore

@Suite(.serialized)
struct VideoResizeTests {
    @Test
    func computesFitFillStretchAndAlignedAspectSizing() throws {
        var options = VideoResizeOptions()
        options.sizing = .dimensions
        options.width = 800
        options.height = 800
        options.locksAspectRatio = false
        let sourceSize = CGSize(width: 1920, height: 1080)

        let fitted = try VideoResizeLayout.plan(sourceSize: sourceSize, options: options)
        #expect(fitted.contentRect == CGRect(x: 0, y: 175, width: 800, height: 450))
        options.framing = .fill
        let filled = try VideoResizeLayout.plan(sourceSize: sourceSize, options: options)
        #expect(abs(filled.contentRect.width - 1422.222) < 0.01)
        #expect(filled.contentRect.minX < 0)
        #expect(filled.contentRect.height == 800)

        options.framing = .stretch
        let stretched = try VideoResizeLayout.plan(sourceSize: sourceSize, options: options)
        #expect(stretched.contentRect == CGRect(x: 0, y: 0, width: 800, height: 800))
        options.locksAspectRatio = true
        options.width = 854
        let locked = try VideoResizeLayout.plan(sourceSize: sourceSize, options: options)
        #expect(locked.width == 854)
        #expect(locked.height == 480)

        options.sizing = .percentage
        options.percentage = 33
        let scaled = try VideoResizeLayout.plan(sourceSize: sourceSize, options: options)
        #expect(scaled.width == 634)
        #expect(scaled.height == 356)
    }

    @Test
    func rejectsUnsupportedDimensionsAndScale() throws {
        var options = VideoResizeOptions()
        options.sizing = .dimensions
        options.locksAspectRatio = false
        options.width = 321
        let size = CGSize(width: 640, height: 480)
        #expect(throws: ToolError.self) { try VideoResizeLayout.plan(sourceSize: size, options: options) }
        options.width = 8192
        #expect(throws: ToolError.self) { try VideoResizeLayout.plan(sourceSize: size, options: options) }
        options.sizing = .percentage
        options.percentage = 0
        #expect(throws: ToolError.self) { try VideoResizeLayout.plan(sourceSize: size, options: options) }
    }

    @Test(arguments: [VideoResizeFraming.fit, .fill])
    func previewAndMP4MatchFramingForRotatedInput(framing: VideoResizeFraming) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.makePortraitVideo(in: directory)
        #expect(try await VideoResize.sourceSize(source) == CGSize(width: 64, height: 128))

        let output = directory.appending(path: "resized.mp4")
        var options = VideoResizeOptions()
        options.sizing = .dimensions
        options.locksAspectRatio = false
        options.width = 96
        options.height = 96
        options.framing = framing

        let preview = try await VideoResize.preview(source, options: options)
        try Self.checkColorPattern(preview, framing: framing)
        _ = try await VideoResize.export(source, to: output, options: options) { _ in }
        let report = try await MediaInspection.inspect(output)
        #expect(report.summary.contains("Dimensions: 96 × 96"))

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let frame = try await generator.image(at: CMTime(value: 1, timescale: 4)).image
        try Self.checkColorPattern(frame, framing: framing)
    }

    private static func checkColorPattern(_ image: CGImage, framing: VideoResizeFraming) throws {
        #expect(image.width == 96)
        #expect(image.height == 96)
        let context = try #require(CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
                                             bytesPerRow: 384, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func color(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = y * context.bytesPerRow + x * 4
            return Array(UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 3))
        }
        let edge = color(4, 24)
        #expect(framing == .fit ? edge.allSatisfy { $0 < 20 } : edge.contains { $0 > 100 })
        let upper = color(48, 24)
        let lower = color(48, 72)
        #expect(upper[0] > 100 && lower[1] > 100 || upper[1] > 100 && lower[0] > 100)
    }

    static func makePortraitVideo(in directory: URL) async throws -> URL {
        let url = directory.appending(path: "rotated.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 64
        ])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 128, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        let bytes = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        for row in 0..<64 {
            for column in 0..<128 {
                let offset = row * CVPixelBufferGetBytesPerRow(frame) + column * 4
                bytes[offset] = 0
                bytes[offset + 1] = column >= 64 ? 255 : 0
                bytes[offset + 2] = column < 64 ? 255 : 0
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0..<24 {
            for _ in 0..<500 where !input.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(for: .milliseconds(2))
            }
            try #require(input.isReadyForMoreMediaData)
            try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishMediaWriting()
        try #require(writer.status == .completed)
        return url
    }
}
