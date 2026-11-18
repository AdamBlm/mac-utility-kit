import AVFoundation
import Testing
import UtilityCore

struct AudioRecordingTests {
    @Test
    func levelClampsInvalidSignalAndFlagsNearClipping() {
        let silence = AudioCaptureLevel(averageDB: -.infinity, peakDB: .nan)
        #expect(silence == .silence)
        #expect(silence.meterFraction == 0)
        let normal = AudioCaptureLevel(averageDB: -30, peakDB: -12)
        #expect(normal.meterFraction == 0.5)
        #expect(!normal.isNearClipping)
        let clip = AudioCaptureLevel(averageDB: 3, peakDB: -0.5)
        #expect(clip.meterFraction == 1)
        #expect(clip.isNearClipping)
    }

    @Test
    func validatesAndSavesPlayableRecordingFromSyntheticAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "synthetic.m4a")
        let saved = folder.appending(path: "saved.m4a")
        try Self.writeAudio(to: source)
        let recording = try await AudioRecordingFile.inspect(source)
        #expect(abs(recording.duration - 0.5) < 0.05)
        try await recording.save(to: saved)
        #expect(try Data(contentsOf: source) == Data(contentsOf: saved))
        let reopened = try await AudioRecordingFile.inspect(saved)
        #expect(reopened.duration == recording.duration)
        try Data("invalid".utf8).write(to: saved, options: .atomic)
        try await recording.save(to: saved)
        #expect(try Data(contentsOf: source) == Data(contentsOf: saved))
        await #expect(throws: ToolError.self) { try await recording.save(to: source) }
        let empty = folder.appending(path: "empty.m4a")
        try Data().write(to: empty)
        await #expect(throws: (any Error).self) { try await AudioRecordingFile.inspect(empty) }
    }

    private static func writeAudio(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?.pointee)
        for index in 0..<24_000 {
            channel[index] = Float(0.5 * sin(2 * .pi * 440 * Double(index) / 48_000))
        }
        try file.write(from: buffer)
    }
}
