import AVFoundation
import Testing
import UtilityCore

struct AudioMergeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func normalizesMixedClipsAndPreservesOrderThroughTransitions() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "A [first].wav")
        let second = folder.appending(path: "B [second].wav")
        try makeClip(first, rate: 44_100, level: 0.2)
        try makeClip(second, rate: 48_000, level: -0.4)
        let linked = folder.appending(path: "Linked second.wav")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: second)
        let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
        var options = AudioMergeOptions()
        options.ffmpegExecutable = URL(fileURLWithPath: executable)
        options.format = .wav
        options.stereo = false
        options.transitionMilliseconds = 250

        for (transition, frames) in [
            (AudioMergeOptions.Transition.cut, 96_000), (.gap, 108_000), (.crossfade, 84_000),
        ] {
            options.transition = transition
            let output = folder.appending(path: "\(transition).wav")
            _ = try await AudioMerge.export([linked, first], to: output, options: options) { _ in }
            let file = try AVAudioFile(forReading: output)
            #expect(file.length == frames)
            #expect(file.processingFormat.sampleRate == 48_000)
            #expect(file.processingFormat.channelCount == 1)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData?[0])
            #expect(abs(samples[1_000] + 0.4) < 0.01)
            #expect(abs(samples[frames - 1_000] - 0.2) < 0.01)
            if transition == .gap { #expect(abs(samples[54_000]) < 0.01) }
            if transition == .crossfade { #expect(abs(samples[42_000] + 0.1) < 0.01) }
        }

        options.transition = .crossfade
        options.transitionMilliseconds = 1_001
        let invalid = folder.appending(path: "invalid.wav")
        await #expect(throws: ToolError.self) {
            try await AudioMerge.export([first, second], to: invalid, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: invalid.path))
    }


    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func exportsPlayableAudioInEveryOfferedFormat() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "input.wav")
        try makeClip(source, rate: 44_100, level: 0.2)
        let executable = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"])
        var options = ToolOptions()
        options.audioMerge.ffmpegExecutable = URL(fileURLWithPath: executable)
        options.audioMerge.sampleRate = 44_100

        for format in AudioOutputFormat.allCases {
            options.audioMerge.format = format
            let result = try await ToolRunner.run(
                .mergeAudio, inputs: [source, source], destination: folder, imageSize: 0, options: options
            ) { _ in }
            let output = try #require(result.outputs.first)
            #expect(result.outputs.count == 1)
            #expect(output.pathExtension == format.rawValue)
            #expect(result.failures.isEmpty)
            let file = try AVAudioFile(forReading: output)
            #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2) < 0.1)
            #expect(file.processingFormat.channelCount == 2)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func rejectsAClipReplacedBeforeFFmpegReadsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.wav")
        let second = folder.appending(path: "second.wav")
        let replacement = folder.appending(path: "replacement.wav")
        let clips: [(URL, Float)] = [(first, 0.1), (second, 0.2), (replacement, 0.3)]
        for (clip, level) in clips {
            try makeClip(clip, rate: 48_000, level: level)
        }
        var options = AudioMergeOptions()
        options.format = .wav
        options.ffmpegExecutable = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let output = folder.appending(path: "output.wav")
        await #expect {
            try await AudioMerge.export([first, second], to: output, options: options) { progress in
                if progress == 0.05 {
                    do { _ = try FileManager.default.replaceItemAt(second, withItemAt: replacement) }
                    catch { Issue.record("Could not replace the audio fixture: \(error)") }
                }
            }
        } throws: { error in
            error.localizedDescription == "second.wav changed during merging. Try again."
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["first.wav", "second.wav"])
    }

    private func makeClip(_ output: URL, rate: Double, level: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = level }
        let file = try AVAudioFile(forWriting: output, settings: format.settings)
        try file.write(from: buffer)
    }
}
