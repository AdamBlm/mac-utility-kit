import AVFoundation
import Testing
@testable import UtilityCore

@Suite(.serialized)
struct AudioTrimTests {
    @Test(arguments: [AudioTrimFormat.wav, .aiff])
    func losslessCopiesOriginal24BitSamples(format: AudioTrimFormat) async throws {
        let folder = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "source.\(format.rawValue)")
        let output = folder.appending(path: "cut.\(format.rawValue)")
        try Self.makeSource(input, format: format, allSamplesEqual: false)
        let alias = folder.appending(path: "linked.\(format.rawValue)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let source = try AudioTrim.source(alias)
        #expect(source.losslessFormat == format)
        var options = AudioTrimOptions()
        options.mode = .lossless
        options.format = format
        options.start = 0.125
        options.end = 0.625
        _ = try await AudioTrim.export(alias, to: output, options: options) { _ in }
        let exact = try Self.samples(in: input)
        let trimmed = try Self.samples(in: output)
        #expect(trimmed == Array(exact[6000..<30000]))
        let formatDescription = try AVAudioFile(forReading: output).fileFormat
        let description = formatDescription.streamDescription.pointee
        #expect(description.mBitsPerChannel == 24)
    }

    @Test(arguments: [AudioTrimFormat.wav, .aiff, .m4a])
    func appliesFadesAndProducesCorrectLength(format: AudioTrimFormat) async throws {
        let folder = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "source.wav")
        let output = folder.appending(path: "cut.\(format.rawValue)")
        try Self.makeSource(input, format: .wav, allSamplesEqual: true)
        var options = AudioTrimOptions()
        options.format = format
        options.start = 0.125
        options.end = 0.625
        options.fadeIn = 0.1
        options.fadeOut = 0.1
        let waveform = try await AudioTrim.waveform(input, bins: 20)
        #expect(waveform.peaks.count == 20)
        #expect(waveform.peaks.allSatisfy { abs($0 - 0.5) < 0.01 })
        _ = try await AudioTrim.export(input, to: output, options: options) { _ in }

        let file = try AVAudioFile(forReading: output)
        #expect(file.processingFormat.sampleRate == 48_000)
        if format == .m4a {
            #expect(abs(file.length - 24_000) < 2400)
            #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        } else {
            let values = try Self.samples(in: output)
            #expect(values.count == 24_000)
            #expect(values.first == 0)
            #expect(values.last == 0)
            #expect(abs(Int64(values[2400]) - Int64(Int32.max / 4)) < 1_000_000)
            #expect(abs(Int64(values[12_000]) - Int64(Int32.max / 2)) < 1_000_000)
        }
    }

    @Test
    func rejectsEmptySelectionsAndEffectsInLosslessMode() throws {
        let source = AudioTrimSource(sampleRate: 48_000, frameCount: 48_000, losslessFormat: .wav)
        var options = AudioTrimOptions()
        options.start = 0.75
        options.end = 0.75
        #expect(throws: ToolError.self) { try AudioTrimSelection.plan(source, options: options) }
        options.start = 0
        options.mode = .lossless
        options.fadeIn = 0.05
        #expect(throws: ToolError.self) { try AudioTrimSelection.plan(source, options: options) }
        options.fadeIn = 0
        options.format = .aiff
        #expect(throws: ToolError.self) { try AudioTrimSelection.plan(source, options: options) }
    }

    @Test
    func mixedBatchPublishesOnlyCompatibleLosslessTrim() async throws {
        let folder = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let aiff = folder.appending(path: "first.aiff")
        let wav = folder.appending(path: "second.wav")
        try Self.makeSource(aiff, format: .aiff, allSamplesEqual: false)
        try Self.makeSource(wav, format: .wav, allSamplesEqual: false)

        var options = ToolOptions()
        options.audioTrim.mode = .lossless
        options.audioTrim.start = 0.125
        options.audioTrim.end = 0.625
        let selection = try AudioTrimSelection.plan(AudioTrim.source(wav), options: options.audioTrim)
        #expect(throws: ToolError.self) {
            try AudioTrimSelection.plan(AudioTrim.source(aiff), options: options.audioTrim)
        }

        let report = try await ToolRunner.run(.trimAudio, inputs: [aiff, wav], destination: folder,
                                              imageSize: 0, options: options) { _ in }
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("matching output format") == true)
        #expect(report.outputs.count == 1)
        let output = try #require(report.outputs.first)
        let source = try Self.samples(in: wav)
        #expect(try Self.samples(in: output) == Array(source[Int(selection.firstFrame)..<Int(selection.endFrame)]))
    }

    @Test func batchDiscardsAChangedAudioSourceAndKeepsTheOtherTrim() async throws {
        let folder = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appending(path: "Other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let first = folder.appending(path: "source.wav")
        let second = other.appending(path: first.lastPathComponent)
        for clip in [first, second] {
            try Self.makeSource(clip, format: .wav, allSamplesEqual: false)
        }
        let firstBytes = try Data(contentsOf: first)
        var options = ToolOptions()
        options.audioTrim.mode = .lossless
        options.audioTrim.start = 0.125
        options.audioTrim.end = 0.625
        let expected = try AudioTrimSelection.plan(AudioTrim.source(second), options: options.audioTrim)
        let report = try await ToolRunner.run(.trimAudio, inputs: [first, second], destination: folder,
                                              imageSize: 0, options: options) { fraction in
            if fraction == 0.99 / 2 {
                do { try firstBytes.write(to: first, options: .atomic) }
                catch { Issue.record("Could not replace the audio fixture: \(error)") }
            }
        }
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("1 - source.wav — The audio source changed") == true)
        #expect(report.outputs.map(\.lastPathComponent) == ["2 - source.wav"])
        let output = try #require(report.outputs.first)
        let samples = try Self.samples(in: second)
        #expect(try Self.samples(in: output) == Array(samples[Int(expected.firstFrame)..<Int(expected.endFrame)]))
    }

    private static func makeDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private static func makeSource(_ url: URL, format: AudioTrimFormat, allSamplesEqual: Bool) throws {
        let writer = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsBigEndianKey: format == .aiff
        ], commonFormat: .pcmFormatInt32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.int32ChannelData?.pointee)
        for i in 0..<48_000 {
            channel[i] = allSamplesEqual ? 1_073_741_824 : Int32((i * 997 % 16_000_000) - 8_000_000) << 8
        }
        try writer.write(from: buffer)
    }

    private static func samples(in url: URL) throws -> [Int32] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.int32ChannelData?.pointee)
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
