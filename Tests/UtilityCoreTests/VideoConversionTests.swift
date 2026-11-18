import AVFoundation
import Foundation
import Testing
import UtilityCore

@Test func videoConversionExportsPlayableH264() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try await conversionFixture(in: folder)
    let output = folder.appendingPathComponent("converted.mp4")

    let summary = try await VideoConversion.convert(source, to: output, options: .init()) { _ in }
    let result = AVURLAsset(url: output)
    #expect(try await result.load(.isPlayable))
    let tracks = try await result.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let formats = try await track.load(.formatDescriptions)
    let format = try #require(formats.first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    #expect(summary.contains("MP4 · H.264"))
}

@Test func videoConversionPassthroughKeepsCodec() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try await conversionFixture(in: folder)
    let output = folder.appendingPathComponent("copied.mov")
    var options = VideoConversionOptions()
    options.format = .mov
    options.mode = .passthrough
    let summary = try await VideoConversion.convert(source, to: output, options: options) { _ in }

    let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let formats = try await track.load(.formatDescriptions)
    let format = try #require(formats.first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_AppleProRes422)
    #expect(summary.contains("MOV"))
}

@Test func videoConversionRejectsIncompatibleOptionsBeforeWritingOutput() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try await conversionFixture(in: folder)
    let output = folder.appendingPathComponent("unsupported.webm")
    var options = VideoConversionOptions()
    options.format = .webm
    await #expect(throws: ToolError.self) { try await VideoConversion.convert(source, to: output, options: options) { _ in } }
    options.codec = .vp9
    await #expect(throws: ToolError.self) { try await VideoConversion.convert(source, to: output, options: options) { _ in } }
    options.mode = .passthrough
    options.frameRate = 20
    await #expect(throws: ToolError.self) { try await VideoConversion.convert(source, to: output, options: options) { _ in } }
    #expect(!FileManager.default.fileExists(atPath: output.path))

    let existing = folder.appendingPathComponent("existing.mp4")
    let original = Data("keep this file".utf8)
    try original.write(to: existing)
    await #expect(throws: ToolError.self) {
        try await VideoConversion.convert(source, to: existing, options: .init()) { _ in }
    }
    #expect(try Data(contentsOf: existing) == original)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func videoConversionUsingFFmpegSupportsWebMAndCustomVideoSettings() async throws {
    guard let executable = ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] else { return }
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try await conversionFixture(in: folder)
    var options = VideoConversionOptions()
    options.ffmpegExecutable = URL(fileURLWithPath: executable)
    options.maximumHeight = 48
    options.frameRate = 12
    options.audio = .remove

    let mp4 = folder.appendingPathComponent("custom.mp4")
    _ = try await VideoConversion.convert(source, to: mp4, options: options) { _ in }
    let tracks = try await AVURLAsset(url: mp4).loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let size = try await track.load(.naturalSize)
    #expect(size.height == 48)
    #expect(try await track.load(.nominalFrameRate) == 12)

    options.format = .webm
    options.codec = .vp9
    let webm = folder.appendingPathComponent("custom.webm")
    let summary = try await VideoConversion.convert(source, to: webm, options: options) { _ in }
    #expect(summary.contains("VP9"))
    #expect(try Data(contentsOf: webm).starts(with: [0x1a, 0x45, 0xdf, 0xa3]))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func videoConversionCanKeepOrRemoveAudioWithNativePassthrough() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = try await conversionFixture(in: folder)
    let source = folder.appendingPathComponent("with-audio.mp4")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [
        "-nostdin", "-v", "error", "-i", video.path,
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-c:v", "libx264", "-c:a", "aac", "-shortest", source.path
    ]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)

    var options = VideoConversionOptions()
    options.mode = .passthrough
    let withAudio = folder.appendingPathComponent("kept.mp4")
    let kept = try await VideoConversion.convert(source, to: withAudio, options: options) { _ in }
    #expect(kept.contains("AAC"))
    #expect(try await AVURLAsset(url: withAudio).loadTracks(withMediaType: .audio).count == 1)

    options.audio = .remove
    let withoutAudio = folder.appendingPathComponent("muted.mp4")
    let muted = try await VideoConversion.convert(source, to: withoutAudio, options: options) { _ in }
    #expect(muted.contains("1 audio track dropped"))
    #expect(try await AVURLAsset(url: withoutAudio).loadTracks(withMediaType: .audio).isEmpty)
}

private func conversionFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

func conversionFixture(in folder: URL) async throws -> URL {
    let url = folder.appendingPathComponent("fixture.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let width = 128
    let height = 96
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: width, AVVideoHeightKey: height
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    var pixelBuffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
    ) == kCVReturnSuccess)
    let frame = try #require(pixelBuffer)
    CVPixelBufferLockBaseAddress(frame, [])
    if let bytes = CVPixelBufferGetBaseAddress(frame) {
        memset(bytes, 120, CVPixelBufferGetBytesPerRow(frame) * height)
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    for index in 0..<12 {
        for _ in 0..<500 where !input.isReadyForMoreMediaData && writer.status == .writing {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(input.isReadyForMoreMediaData)
        try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
    return url
}
