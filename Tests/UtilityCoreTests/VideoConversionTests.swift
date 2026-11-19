import AVFoundation
import Foundation
import Testing
@testable import UtilityCore

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
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func videoConversionReportsObservedWebMCodecsAndDroppedStreams() async throws {
    let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = ["-f", "lavfi", "-i", "testsrc2=s=80x48:r=10:d=1", "-f", "lavfi", "-i", "sine=d=1"]
    func fixture(_ arguments: [String], named filename: String) throws -> URL {
        let file = folder.appending(path: filename)
        let writer = Process()
        writer.executableURL = executable
        writer.arguments = ["-nostdin", "-v", "error"] + sources + arguments + [file.path]
        try writer.run()
        writer.waitUntilExit()
        try #require(writer.terminationStatus == 0)
        return file
    }

    var options = VideoConversionOptions()
    options.ffmpegExecutable = executable
    options.format = .webm
    options.mode = .passthrough
    let incompatible = try fixture(["-c:v", "libx264", "-c:a", "aac"], named: "H264.mp4")
    await #expect(throws: ToolError.self) {
        try await VideoConversion.checkWebMPassthrough(incompatible, audio: .keep, executable: executable)
    }
    let mixedAudio = try fixture(["-c:v", "libvpx-vp9", "-c:a", "aac"], named: "VP9 AAC.mkv")
    await #expect(throws: ToolError.self) {
        try await VideoConversion.checkWebMPassthrough(mixedAudio, audio: .keep, executable: executable)
    }
    try await VideoConversion.checkWebMPassthrough(mixedAudio, audio: .remove, executable: executable)
    let audioOnly = try fixture(["-map", "1:a", "-c:a", "libopus"], named: "Audio only.webm")
    await #expect(throws: ToolError.self) {
        try await VideoConversion.checkWebMPassthrough(audioOnly, audio: .keep, executable: executable)
    }
    for (encoder, audioEncoder, video, audio) in [
        ("libvpx", "libvorbis", "VP8", "Vorbis"),
        ("libvpx-vp9", "libopus", "VP9", "Opus")
    ] {
        let input = try fixture(["-c:v", encoder, "-c:a", audioEncoder], named: "\(video).webm")
        try await VideoConversion.checkWebMPassthrough(input, audio: .keep, executable: executable)
        let output = folder.appending(path: "\(video) copy.webm")
        let summary = try await VideoConversion.convert(input, to: output, options: options) { _ in }
        #expect(summary.contains("Video: \(video) · Audio: \(audio)"))
        #expect(!summary.contains("dropped"))
    }

    let subtitle = folder.appending(path: "Sample.srt")
    try Data("1\n00:00:00,100 --> 00:00:00,900\nCaption\n".utf8).write(to: subtitle)
    let multi = try fixture([
        "-i", subtitle.path, "-map", "0:v", "-map", "0:v", "-map", "1:a", "-map", "2:s",
        "-c:v", "libx264", "-c:a", "aac", "-c:s", "srt"
    ], named: "Multiple tracks.mkv")
    options.mode = .transcode
    options.codec = .vp9
    options.audio = .remove
    let webm = folder.appending(path: "One track.webm")
    let summary = try await VideoConversion.convert(multi, to: webm, options: options) { _ in }
    for detail in ["Video: VP9", "No audio", "1 audio track dropped", "1 video track dropped", "1 subtitle track dropped"] {
        #expect(summary.contains(detail))
    }
}

@Test func webMStreamSummaryWithholdsClaimsForAnIncompleteInventory() throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appending(path: "source.log")
    let output = folder.appending(path: "output.log")
    let complete = """
        [info] Input #0, matroska,webm, from 'clip.webm':
        [info]   Stream #0:0[0x1]: Video: vp9, yuv420p
        [info]   Stream #0:1[0x2](eng): Audio: opus, 48000 Hz
        [info] Stream mapping:
        """
    try Data(complete.utf8).write(to: source)
    try Data(complete.utf8).write(to: output)
    #expect(try FFmpegStreamInventory.webMSummary(input: source, output: output) == "WebM · Video: VP9 · Audio: Opus")

    let variant = complete.replacingOccurrences(of: "Audio: opus", with: "Audio in variant layout")
    try Data(variant.utf8).write(to: output)
    let report = try FFmpegStreamInventory.webMSummary(input: source, output: output)
    #expect(report.contains("Stream details unavailable"))
    #expect(!report.contains("No audio") && !report.contains("dropped"))
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
    await writer.finishMediaWriting()
    try #require(writer.status == .completed)
    return url
}
