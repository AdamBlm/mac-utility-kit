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
        let samples = try #require(buffer.floatChannelData?.pointee)
        #expect(Self.amplitude(samples, frequency: 440, sampleRate: file.fileFormat.sampleRate) > 0.12)
        #expect(Self.amplitude(samples, frequency: 770, sampleRate: file.fileFormat.sampleRate) > 0.12)
        #expect(summary.contains("Mono"))
    }

    @Test func appliesMetadataToggleToAAC() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = try Self.writeStereoWAV(to: directory)
        let initial = directory.appending(path: "untagged.m4a")
        _ = try await AudioConvert.export(wav, to: initial, options: AudioConvertOptions()) { _ in }
        let source = directory.appending(path: "tagged.m4a")
        let exporter = try #require(AVAssetExportSession(asset: AVURLAsset(url: initial), presetName: AVAssetExportPresetPassthrough))
        let tag = AVMutableMetadataItem()
        tag.identifier = .commonIdentifierTitle
        tag.value = "Tagged audio fixture" as NSString
        exporter.metadata = [tag]
        try await exporter.export(to: source, as: .m4a)
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

    private static func writeStereoWAV(to directory: URL) throws -> URL {
        let url = directory.appending(path: "source.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
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
