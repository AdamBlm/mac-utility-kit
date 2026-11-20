import AVFoundation
import Foundation
import Testing
@testable import UtilityCore

@Test func nativeMediaInspectionReadsAudioAndExportsJSON() async throws {
    let folder = try mediaInspectionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let audio = folder.appendingPathComponent("tone.wav")
    try writeInspectionAudio(to: audio)
    let input = try Data(contentsOf: audio)

    let report = try await MediaInspection.inspect(audio)
    #expect(report.summary.contains("tone.wav"))
    #expect(report.summary.contains("Audio track 1"))
    #expect(report.summary.contains("Channels: 1"))
    #expect(report.summary.contains("Overall bitrate (estimated)"))
    let decoded = try JSONDecoder().decode([MediaInspectionReport.Section].self, from: report.json)
    #expect(decoded.first?.title == "File")
    #expect(try Data(contentsOf: audio) == input)
}

@Test func nativeMediaInspectionReadsOrientedVideoAndKeepsTimingSeparate() async throws {
    let folder = try mediaInspectionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appendingPathComponent("portrait.mov")
    try await writeInspectionVideo(to: video)

    let report = try await MediaInspection.inspect(video)
    #expect(report.summary.contains("Dimensions: 64 × 96"))
    #expect(report.summary.contains("Frame rate (nominal):"))
    #expect(report.summary.contains("Frame timing: Variable intervals observed"))
}

@Test(arguments: [false, true])
func nativeMediaInspectionSamplesTimingBeyondTheOpeningFrames(cadenceChanges: Bool) async throws {
    let folder = try mediaInspectionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appending(path: "Longer.mov")
    let opening = (0..<190).map { $0 * 25 }
    let ending = (1...40).map { 189 * 25 + $0 * (cadenceChanges ? 50 : 25) }
    try await writeInspectionVideo(to: video, ticks: opening + ending)

    let report = try await MediaInspection.inspect(video)
    let expected = cadenceChanges ? "Variable intervals observed" : "Even intervals in sampled frames"
    #expect(report.summary.contains("Frame timing: " + expected))
}

@Test func mediaInspectionRejectsNonMedia() async throws {
    let folder = try mediaInspectionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("broken.mov")
    try Data("This is not a video.".utf8).write(to: file)
    await #expect(throws: (any Error).self) {
        try await MediaInspection.inspect(file)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFPROBE_TEST"] != nil))
func ffprobeMediaInspectionPreservesStructuredStreamsWithoutAbsoluteSourcePath() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFPROBE_TEST"])
    let folder = try mediaInspectionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let audio = folder.appendingPathComponent("tone.wav")
    try writeInspectionAudio(to: audio)
    let report = try await MediaInspection.inspect(audio, options: .init(ffprobeExecutable: URL(fileURLWithPath: executable)))
    #expect(report.summary.contains("Audio stream 0"))
    let data = try #require(JSONSerialization.jsonObject(with: report.json) as? [String: Any])
    let format = try #require(data["format"] as? [String: Any])
    #expect(format["filename"] as? String == "tone.wav")
    let streams = try #require(data["streams"] as? [[String: Any]])
    #expect(streams.first?["codec_type"] as? String == "audio")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFPROBE_TEST"] != nil),
      arguments: [false, true])
func ffprobeMediaInspectionReportsObservedCadence(variable: Bool) async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFPROBE_TEST"])
    let folder = try mediaInspectionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appending(path: "Cadence.mov")
    let ticks = variable ? [0, 20, 40, 100, 120, 160, 220, 240] : (0..<8).map { 25 * $0 }
    try await writeInspectionVideo(to: video, ticks: ticks)
    let report = try await MediaInspection.inspect(video, options: .init(ffprobeExecutable: URL(filePath: executable)))
    let expected = variable ? "Variable intervals observed" : "Even intervals in sampled frames"
    #expect(report.summary.contains("Frame rate (average):"))
    #expect(report.summary.contains("Frame timing: " + expected))
}

@Test func ffprobeCadenceDoesNotBridgeMissingPresentationTimestamps() {
    let intervals = FFprobeInspection.adjacentIntervals([0, 40, nil, 120, 160, 200])
    #expect(intervals == [40, 40, 40])
}

@Test func ffprobeCadenceAllowsOneTickOfTimestampQuantization() {
    #expect(MediaInspection.frameTiming(intervals: [0.033, 0.034, 0.033], resolution: 0.001)
        == "Even intervals in sampled frames")
}

private func mediaInspectionFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func writeInspectionAudio(to url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
    buffer.frameLength = 4_410
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) {
        samples[index] = sin(Float(index) * 2 * .pi * 440 / 44_100) * 0.25
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func writeInspectionVideo(
    to url: URL, ticks: [Int] = [0, 20, 40, 100, 120, 160, 220, 240]
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64
    ])
    input.transform = CGAffineTransform(translationX: 64, y: 0).rotated(by: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let frame = try #require(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    if let pixels = CVPixelBufferGetBaseAddress(frame) {
        memset(pixels, 64, CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame))
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    for tick in ticks {
        for _ in 0..<500 where !input.isReadyForMoreMediaData && writer.status == .writing {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(input.isReadyForMoreMediaData)
        try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(tick), timescale: 600)))
    }
    input.markAsFinished()
    await writer.finishMediaWriting()
    try #require(writer.status == .completed)
}
