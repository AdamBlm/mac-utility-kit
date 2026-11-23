import AVFoundation
import Testing
import UtilityCore

struct AudioConvertTests {
    @Test(arguments: [AudioOutputFormat.wav, .aiff, .m4a])
    func nativeChangesRateAndDownmixesBothStereoChannels(format: AudioOutputFormat) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try Self.writeStereoWAV(to: directory)
        var options = AudioConvertOptions()
        options.format = format
        options.sampleRate = 44_100
        options.channels = .mono
        let output = directory.appending(path: "converted." + format.rawValue)
        let summary = try await AudioConvert.export(input, to: output, options: options) { _ in }
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.sampleRate == 44_100 && file.fileFormat.channelCount == 1)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 0.5) < 0.08)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        try #require(Double(buffer.frameLength) / file.fileFormat.sampleRate > 0.4)
        try withExtendedLifetime(buffer) {
            let samples = try #require(buffer.floatChannelData?.pointee)
            #expect(Self.amplitude(samples, frequency: 440, sampleRate: file.fileFormat.sampleRate) > 0.12)
            #expect(Self.amplitude(samples, frequency: 770, sampleRate: file.fileFormat.sampleRate) > 0.12)
        }
        #expect(summary.contains("Mono"))
    }

    @Test(arguments: [false, true])
    func batchPreservesEachSampleRateAndChecksFileSymlinks(retargetLink: Bool) async throws {
        let directory = try Self.makeDirectory()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: directory) }
        let first = try Self.writeStereoWAV(to: directory, sampleRate: 48_000)
        let other = directory.appending(path: "Other", directoryHint: .isDirectory)
        let links = directory.appending(path: "Links", directoryHint: .isDirectory)
        for folder in [other, links] { try manager.createDirectory(at: folder, withIntermediateDirectories: false) }
        let second = try Self.writeStereoWAV(to: other, sampleRate: 44_100)
        let alias = links.appending(path: first.lastPathComponent)
        try manager.createSymbolicLink(at: alias, withDestinationURL: second)
        let corrupt = directory.appending(path: "Bad.wav")
        try Data("not audio".utf8).write(to: corrupt)
        let originals = try [first, second].map { try Data(contentsOf: $0) }

        var options = ToolOptions()
        options.audioConvert = .recommended
        options.audioConvert.format = .wav
        let report = try await ToolRunner.run(.convertAudio, inputs: [first, corrupt, alias],
                                              destination: directory, imageSize: 0, options: options) { fraction in
            if retargetLink, fraction > 2.0 / 3, fraction < 1,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path)) == second.path {
                do {
                    try FileManager.default.removeItem(at: alias)
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
                } catch {
                    Issue.record("Could not retarget the audio fixture: \(error)")
                }
            }
        }

        #expect(report.failures.count == (retargetLink ? 2 : 1))
        #expect(report.failures.first?.hasPrefix("2 - Bad.wav — ") == true)
        if retargetLink {
            #expect(report.failures.last?.contains("3 - source.wav — The source audio changed") == true)
        }
        let names = retargetLink ? ["1 - source.wav"] : ["1 - source.wav", "3 - source.wav"]
        #expect(report.outputs.map(\.lastPathComponent) == names)
        let formats = try report.outputs.map { try AVAudioFile(forReading: $0).fileFormat }
        let rates: [Double] = retargetLink ? [48_000] : [48_000, 44_100]
        #expect(formats.map(\.sampleRate) == rates)
        #expect(formats.allSatisfy { $0.channelCount == 2 })
        #expect(try [first, second].map { try Data(contentsOf: $0) } == originals)
    }

    @Test func appliesMetadataToggleToAAC() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "tagged-audio", withExtension: "m4a"))
        for preserve in [true, false] {
            var options = AudioConvertOptions()
            options.preservesMetadata = preserve
            let output = directory.appending(path: "metadata-\(preserve).m4a")
            _ = try await AudioConvert.export(source, to: output, options: options) { _ in }
            let tags = try await AVURLAsset(url: output).load(.commonMetadata)
            let title = try await tags.first(where: { $0.commonKey == .commonKeyTitle })?.load(.stringValue)
            #expect(title == (preserve ? "Tagged audio fixture" : nil))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil),
          arguments: [AudioOutputFormat.mp3, .flac])
    func externalExportsRequestedCodecRateAndChannels(format: AudioOutputFormat) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = try Self.writeStereoWAV(to: directory)
        var options = AudioConvertOptions()
        options.format = format
        options.channels = .mono
        options.sampleRate = 32_000
        options.ffmpegExecutable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let output = directory.appending(path: "audio." + format.rawValue)
        _ = try await AudioConvert.export(wav, to: output, options: options) { _ in }
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.sampleRate == 32_000 && file.fileFormat.channelCount == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func mp3PreservesLowSourceRatesAndRejectsIncompatibleSettings() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let high = try Self.writeStereoWAV(to: directory, sampleRate: 96_000)
        let low = directory.appending(path: "24k.wav")
        try Self.runFFmpeg(ffmpeg, ["-i", high.path, "-ar", "24000", low.path])

        var options = AudioConvertOptions()
        options.format = .mp3
        options.ffmpegExecutable = ffmpeg
        options.bitrate = 320
        let highFormat = try #require(AudioConvert.sourceFormat(high))
        let lowFormat = try #require(AudioConvert.sourceFormat(low))
        #expect(highFormat.sampleRate == 96_000 && lowFormat.sampleRate == 24_000)
        #expect(options.sourceIssue(highFormat)?.contains("cannot keep the input sample rate") == true)
        #expect(options.sourceIssue(lowFormat)?.contains("cannot use this bitrate") == true)
        let rejected = directory.appending(path: "rejected.mp3")
        let sampleRateError = await #expect(throws: ToolError.self) {
            try await AudioConvert.export(high, to: rejected, options: options) { _ in }
        }
        #expect(sampleRateError?.localizedDescription.contains("MP3 cannot keep the input sample rate") == true)
        let bitrateError = await #expect(throws: ToolError.self) {
            try await AudioConvert.export(low, to: rejected, options: options) { _ in }
        }
        #expect(bitrateError?.localizedDescription.contains("MP3 cannot use this bitrate at the source sample rate") == true)
        options.sampleRate = 24_000
        #expect(options.validationIssue != nil)
        #expect(!options.supportedBitrates.contains(320))
        #expect(!FileManager.default.fileExists(atPath: rejected.path))

        options.bitrate = 144
        options.sampleRate = nil
        #expect(options.sourceIssue(lowFormat) == nil)
        let output = directory.appending(path: "24k.mp3")
        let summary = try await AudioConvert.export(low, to: output, options: options) { _ in }
        let decoded = try AVAudioFile(forReading: output)
        #expect(decoded.fileFormat.sampleRate == 24_000 && decoded.fileFormat.channelCount == 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 512))
        try decoded.read(into: buffer)
        #expect(buffer.frameLength == 512)
        #expect(summary.contains("24 kHz"))

        options.sampleRate = 8_000
        options.bitrate = 32
        let phone = directory.appending(path: "8k.mp3")
        _ = try await AudioConvert.export(high, to: phone, options: options) { _ in }
        #expect(try AVAudioFile(forReading: phone).fileFormat.sampleRate == 8_000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func automaticMP3UsesCompatibleSourceParametersWithoutChangingStrictMode() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let surround = directory.appending(path: "surround.wav")
        let voice = directory.appending(path: "phone.wav")
        try Self.runFFmpeg(ffmpeg, ["-f", "lavfi", "-i", "anullsrc=r=96000:cl=5.1", "-t", "0.25", surround.path])
        try Self.runFFmpeg(ffmpeg, ["-f", "lavfi", "-i", "sine=frequency=600:sample_rate=8000:duration=0.25", voice.path])
        var options = AudioConvertOptions.recommended
        options.format = .mp3
        options.ffmpegExecutable = ffmpeg
        let surroundSource = try #require(AudioConvert.sourceFormat(surround))
        let voiceSource = try #require(AudioConvert.sourceFormat(voice))
        #expect(options.automaticAdjustment(for: surroundSource)?.contains("96 → 48 kHz") == true)
        #expect(options.automaticAdjustment(for: surroundSource)?.contains("6 channels → stereo") == true)
        #expect(options.automaticAdjustment(for: voiceSource) == "64 kbps target")

        let surroundOutput = directory.appending(path: "surround.mp3")
        let voiceOutput = directory.appending(path: "phone.mp3")
        _ = try await AudioConvert.export(surround, to: surroundOutput, options: options) { _ in }
        let voiceSummary = try await AudioConvert.export(voice, to: voiceOutput, options: options) { _ in }
        let stereo = try AVAudioFile(forReading: surroundOutput)
        let mono = try AVAudioFile(forReading: voiceOutput)
        #expect(stereo.fileFormat.sampleRate == 48_000 && stereo.fileFormat.channelCount == 2)
        #expect(mono.fileFormat.sampleRate == 8_000 && mono.fileFormat.channelCount == 1)
        #expect(voiceSummary.contains("64 kbps target"))
        options.automaticallyAdjustsSettings = false
        #expect(options.sourceIssue(surroundSource)?.contains("cannot keep the input sample rate") == true)
        #expect(options.sourceIssue(voiceSource)?.contains("cannot use this bitrate") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func automaticAACUsesTheNativeEncoderCapabilitiesAndDownmixesSurround() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let surround = directory.appending(path: "surround.wav")
        try Self.runFFmpeg(ffmpeg, ["-f", "lavfi", "-i", "anullsrc=r=192000:cl=5.1", "-t", "0.25", surround.path])
        let output = directory.appending(path: "automatic.m4a")
        let options = AudioConvertOptions.recommended
        let source = try #require(AudioConvert.sourceFormat(surround))
        #expect(options.automaticAdjustment(for: source)?.contains("6 channels → stereo") == true)
        _ = try await AudioConvert.export(surround, to: output, options: options) { _ in }
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.sampleRate < 192_000)
        #expect(file.fileFormat.channelCount == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func automaticAACPreservesACompatibleLowSourceRate() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let source = directory.appending(path: "phone.wav")
        try Self.runFFmpeg(ffmpeg, ["-f", "lavfi", "-i", "sine=frequency=600:sample_rate=8000:duration=0.25", source.path])
        let output = directory.appending(path: "automatic.m4a")
        let sourceFormat = try #require(AudioConvert.sourceFormat(source))
        let adjustment = try #require(AudioConvertOptions.recommended.automaticAdjustment(for: sourceFormat))
        #expect(adjustment.contains("kbps target"))
        let summary = try await AudioConvert.export(source, to: output, options: .recommended) { _ in }
        #expect(summary.contains(adjustment))
        let format = try AVAudioFile(forReading: output).fileFormat
        #expect(format.sampleRate == 8_000)
        #expect(format.channelCount == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func metadataDisabledStripsChaptersFromMP3() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = try Self.writeStereoWAV(to: directory)
        let metadata = directory.appending(path: "tags.ffmeta")
        let tags = ";FFMETADATA1\ntitle=Recording\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=300\ntitle=Opening\n"
        try Data(tags.utf8).write(to: metadata)
        let source = directory.appending(path: "source.mka")
        let ffmpeg = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        try Self.runFFmpeg(ffmpeg, ["-i", wav.path, "-f", "ffmetadata", "-i", metadata.path, "-map_metadata", "1",
                                   "-map_chapters", "1", "-c:a", "pcm_s16le", source.path])
        for preserve in [true, false] {
            var options = AudioConvertOptions()
            options.format = .mp3
            options.ffmpegExecutable = ffmpeg
            options.preservesMetadata = preserve
            let output = directory.appending(path: "chapters-\(preserve).mp3")
            _ = try await AudioConvert.export(source, to: output, options: options) { _ in }
            let inspected = directory.appending(path: "chapters-\(preserve).ffmeta")
            try Self.runFFmpeg(ffmpeg, ["-i", output.path, "-f", "ffmetadata", inspected.path])
            let contents = try String(contentsOf: inspected, encoding: .utf8)
            #expect(contents.contains("[CHAPTER]") == preserve)
            #expect(contents.contains("title=Recording") == preserve)
        }
    }

    private static func runFFmpeg(_ executable: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"] + args
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test func rejectsAChosenDirectoryOnlyForFormatsThatUseFFmpeg() {
        var options = AudioConvertOptions()
        options.ffmpegExecutable = FileManager.default.temporaryDirectory
        options.format = .flac
        #expect(options.validationIssue == "Choose an FFmpeg executable for FLAC output.")
        options.format = .wav
        #expect(options.validationIssue == nil)
    }

    @Test func catchesUnsupportedSampleRateBeforeWriting() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try Self.writeStereoWAV(to: directory)
        var options = AudioConvertOptions()
        options.format = .mp3
        options.sampleRate = 96_000
        let output = directory.appending(path: "invalid.mp3")
        await #expect(throws: ToolError.self) {
            try await AudioConvert.export(input, to: output, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func cancelledConversionDoesNotPublishPartialOutput() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try Self.writeStereoWAV(to: directory)
        let output = directory.appending(path: "cancelled.wav")
        var options = AudioConvertOptions()
        options.format = .wav
        let settings = options
        let conversion = Task {
            try await AudioConvert.export(input, to: output, options: settings) { value in
                if value < 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await conversion.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.wav"])
    }

    private static func amplitude(_ samples: UnsafePointer<Float>, frequency: Double, sampleRate: Double) -> Double {
        let start = Int(sampleRate * 0.1)
        let end = Int(sampleRate * 0.4)
        var left = 0.0
        var right = 0.0
        for index in start..<end {
            let theta = 2 * .pi * frequency * Double(index) / sampleRate
            left += Double(samples[index]) * cos(theta)
            right += Double(samples[index]) * sin(theta)
        }
        return 2 * hypot(left, right) / Double(end - start)
    }

    private static func writeStereoWAV(to directory: URL, sampleRate: Double = 48_000) throws -> URL {
        let url = directory.appending(path: "source.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 2)))
        buffer.frameLength = buffer.frameCapacity
        let values = try #require(buffer.floatChannelData)
        for index in 0..<Int(buffer.frameLength) {
            values[0][index] = Float(0.5 * sin(2 * .pi * 440 * Double(index) / format.sampleRate))
            values[1][index] = Float(0.5 * sin(2 * .pi * 770 * Double(index) / format.sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
