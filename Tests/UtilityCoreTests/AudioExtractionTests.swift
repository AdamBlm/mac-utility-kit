import AVFoundation
import Foundation
import Testing
@testable import UtilityCore

private func audioFixture(in folder: URL, seconds: Double = 0.4) throws -> URL {
    let input = folder.appendingPathComponent(UUID().uuidString + ".wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let frames = AVAudioFrameCount(seconds * format.sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(frames) {
        samples[frame] = 0.25 * sin(Float(frame) * 440 * 2 * .pi / Float(format.sampleRate))
    }
    let writer = try AVAudioFile(forWriting: input, settings: format.settings)
    try writer.write(from: buffer)
    return input
}

private func audioTestFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

@Test func extractsNativeAudioFormatsWithAudibleSamples() async throws {
    let folder = try audioTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try audioFixture(in: folder)
    let track = try #require(try await AudioExtraction.trackList(input).first)
    #expect(track.index == 0)
    #expect(track.channels == 1)
    #expect(track.codec == "PCM")

    for format in [AudioOutputFormat.m4a, .wav, .aiff] {
        let output = folder.appendingPathComponent("Extracted.\(format.rawValue)")
        var options = AudioExtractionOptions()
        options.format = format
        _ = try await AudioExtraction.extract(input, to: output, options: options) { _ in }
        let result = try AVAudioFile(forReading: output)
        let duration = Double(result.length) / result.processingFormat.sampleRate
        #expect(abs(duration - 0.4) < 0.05)
        #expect(result.processingFormat.channelCount == 1)
        let decoded = try #require(AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: 1_024))
        try result.read(into: decoded)
        let samples = try #require(decoded.floatChannelData?[0])
        #expect((0..<Int(decoded.frameLength)).contains { abs(samples[$0]) > 0.05 })
    }
}

@Test func audioPreviewTrimsToFiveSecondsAndPassthroughRejectsPCM() async throws {
    let folder = try audioTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try audioFixture(in: folder, seconds: 6)
    let preview = folder.appendingPathComponent("Preview.m4a")
    try await AudioExtraction.preview(input, to: preview, options: AudioExtractionOptions())
    let duration = try await AVURLAsset(url: preview).load(.duration).seconds
    #expect(abs(duration - 5) < 0.05)

    let output = folder.appendingPathComponent("Copied.m4a")
    var options = AudioExtractionOptions()
    options.passthrough = true
    await #expect(throws: ToolError.self) {
        try await AudioExtraction.extract(input, to: output, options: options) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))

    _ = try await AudioExtraction.extract(preview, to: output, options: options) { _ in }
    let copied = try #require(try await AudioExtraction.trackList(output).first)
    #expect(copied.codec == "AAC")
    #expect(abs(try await AVURLAsset(url: output).load(.duration).seconds - duration) < 0.05)
}

@Test func extractionRejectsInvalidExternalEncoderBeforeReadingSource() async throws {
    let folder = FileManager.default.temporaryDirectory
    var options = AudioExtractionOptions()
    options.format = .flac
    options.ffmpegExecutable = folder
    let error = await #expect(throws: ToolError.self) {
        try await AudioExtraction.extract(folder, to: folder, options: options) { _ in }
    }
    #expect(error?.localizedDescription == "Choose an FFmpeg executable to export FLAC.")
    options.format = .m4a
    #expect(options.validationIssue == nil)
}

@Test func unavailableAudioTrackLeavesNoOutput() async throws {
    let folder = try audioTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try audioFixture(in: folder)
    let output = folder.appendingPathComponent("Missing.m4a")
    var options = AudioExtractionOptions()
    options.trackIndex = 3
    await #expect(throws: ToolError.self) {
        try await AudioExtraction.extract(input, to: output, options: options) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

private func makeTaggedAudioTracks(
    _ tracks: [(Double, String)], in folder: URL, at input: URL
) async throws {
    let composition = AVMutableComposition()
    for (seconds, language) in tracks {
        let source = try audioFixture(in: folder, seconds: seconds)
        let asset = AVURLAsset(url: source)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let track = try #require(composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try track.insertTimeRange(try await audio.load(.timeRange), of: audio, at: .zero)
        track.extendedLanguageTag = language
    }
    let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    try await exporter.exportMedia(to: input, as: .mov)
}

@Test func languageSelectionHandlesReorderedMissingAndAmbiguousTracksInOneBatch() async throws {
    let folder = try audioTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let first = folder.appending(path: "English first.mov")
    let second = folder.appending(path: "English second.mov")
    let missing = folder.appending(path: "French only.mov")
    let duplicate = folder.appending(path: "Two English tracks.mov")
    try await makeTaggedAudioTracks([(0.4, "en-US"), (0.8, "fr")], in: folder, at: first)
    try await makeTaggedAudioTracks([(0.8, "fr"), (0.4, "en-GB")], in: folder, at: second)
    try await makeTaggedAudioTracks([(0.8, "fr")], in: folder, at: missing)
    try await makeTaggedAudioTracks([(0.4, "en-US"), (0.6, "en-GB")], in: folder, at: duplicate)

    var options = ToolOptions()
    options.extraction.trackLanguage = "eng"
    let report = try await ToolRunner.run(.extractAudio, inputs: [first, second, missing, duplicate],
                                          destination: folder, imageSize: 0, options: options) { _ in }
    #expect(report.outputs.count == 2)
    #expect(report.failures.count == 2)
    #expect(report.failures.contains { $0.contains("French only.mov") && $0.contains("No audio track is tagged") })
    #expect(report.failures.contains { $0.contains("Two English tracks.mov") && $0.contains("Multiple audio tracks") })
    for output in report.outputs {
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 0.4) < 0.05)
        let track = try #require(try await AudioExtraction.trackList(output).first)
        #expect(track.languageCode == "en")
    }
    let sample = folder.appending(path: "Preview.m4a")
    try await AudioExtraction.preview(second, to: sample, options: options.extraction)
    #expect(abs(try await AVURLAsset(url: sample).load(.duration).seconds - 0.4) < 0.05)
    var legacy = AudioExtractionOptions()
    legacy.trackLanguage = "fre"
    let french = folder.appending(path: "French.m4a")
    _ = try await AudioExtraction.extract(second, to: french, options: legacy) { _ in }
    #expect(abs(try await AVURLAsset(url: french).load(.duration).seconds - 0.8) < 0.05)
}

@Test func extractsOnlyTheChosenLanguageTrack() async throws {
    let folder = try audioTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let input = folder.appending(path: "Two tracks.mov")
    try await makeTaggedAudioTracks([(0.4, "en"), (0.8, "fr")], in: folder, at: input)
    let tracks = try await AudioExtraction.trackList(input)
    #expect(tracks.count == 2)
    let french = try #require(tracks.first { $0.language?.hasPrefix("fr") == true })
    let output = folder.appendingPathComponent("French.m4a")
    var options = AudioExtractionOptions()
    options.trackIndex = french.index
    _ = try await AudioExtraction.extract(input, to: output, options: options) { _ in }
    let extracted = try await AudioExtraction.trackList(output)
    #expect(extracted.map(\.language) == [french.language])
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    #expect(abs(duration - 0.8) < 0.05)

    if let path = ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] {
        let flac = folder.appendingPathComponent("French.flac")
        options.format = .flac
        options.ffmpegExecutable = URL(fileURLWithPath: path)
        _ = try await AudioExtraction.extract(input, to: flac, options: options) { _ in }
        let file = try AVAudioFile(forReading: flac)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 0.8) < 0.05)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
func extractsAudioUsingFFmpegWhenConfigured() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
    let folder = try audioTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try audioFixture(in: folder)
    for format in [AudioOutputFormat.mp3, .flac] {
        let output = folder.appendingPathComponent("Extracted.\(format.rawValue)")
        var options = AudioExtractionOptions()
        options.format = format
        options.ffmpegExecutable = URL(fileURLWithPath: path)
        _ = try await AudioExtraction.extract(source, to: output, options: options) { _ in }
        let track = try #require(try await AudioExtraction.trackList(output).first)
        #expect(track.codec == format.title)
        let result = try AVAudioFile(forReading: output)
        #expect(result.length > 0)
    }
}
