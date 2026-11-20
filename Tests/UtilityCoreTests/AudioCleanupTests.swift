import AVFoundation
import Testing
import UtilityCore

@Suite(.serialized)
struct AudioCleanupTests {
    @Test func validatesFFmpegAndReductionBeforePreview() {
        var options = AudioCleanupOptions()
        options.executable = FileManager.default.temporaryDirectory
        #expect(options.validationIssue == "Choose an FFmpeg executable.")
        options.executable = URL(fileURLWithPath: "/usr/bin/true")
        options.reductionDB = 25
        #expect(options.validationIssue == "Choose a valid audio track and noise reduction from 0 to 24 dB.")
        options.reductionDB = 12
        #expect(options.validationIssue == nil)
    }

    @Test
    func validatesToolAndReductionBeforeExport() async throws {
        let folder = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "input.wav")
        try Data().write(to: source)
        let output = folder.appending(path: "output.wav")
        var options = AudioCleanupOptions()
        await #expect(throws: ToolError.self) {
            try await AudioCleanup.export(source, to: output, options: options) { _ in }
        }
        options.executable = source
        options.reductionDB = 25
        await #expect(throws: ToolError.self) {
            try await AudioCleanup.export(source, to: output, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func humSuppressionPreservesVoiceBandAndMatchesABLevel() async throws {
        let engine = try Self.executable()
        let folder = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "input.wav")
        let output = folder.appending(path: "cleaned.wav")
        _ = try Self.run(engine, [
            "-f", "lavfi", "-i",
            "aevalsrc=0.5*sin(2*PI*60*t)+0.24*sin(2*PI*120*t)+0.12*sin(2*PI*1000*t):s=48000:d=3",
            "-c:a", "pcm_f32le", source.path
        ])
        var options = AudioCleanupOptions()
        options.executable = engine
        options.hum = .hz60
        options.reductionDB = 0
        let comparison = try await AudioCleanup.preview(source, options: options, start: 0, duration: 2)
        let dry = folder.appending(path: "dry.wav")
        let wet = folder.appending(path: "wet.wav")
        try comparison.original.write(to: dry)
        try comparison.cleaned.write(to: wet)
        let drySignal = try Self.samples(in: dry)
        let wetSignal = try Self.samples(in: wet)
        #expect(abs(Self.rms(drySignal) * Double(comparison.originalVolume)
                    - Self.rms(wetSignal) * Double(comparison.cleanedVolume)) < 0.001)
        #expect(!comparison.isNearClipping)

        _ = try await AudioCleanup.export(source, to: output, options: options) { _ in }
        let signal = try Self.samples(in: output)
        let original = try Self.samples(in: source)
        #expect(signal.count == original.count)
        #expect(Self.amplitude(signal, at: 60) < 0.015)
        #expect(Self.amplitude(signal, at: 120) < 0.015)
        #expect(abs(Self.amplitude(signal, at: 1000) - 0.12) < 0.01)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func previewWarnsForNativeChannelPeaksHiddenByPlaybackDownmix() async throws {
        let engine = try Self.executable()
        let folder = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "mono.wav")
        _ = try Self.run(engine, [
            "-f", "lavfi", "-i", "aevalsrc='(0.2+0.9*gte(t,0.5))*sin(2*PI*1000*t)':s=48000:d=1",
            "-c:a", "pcm_f32le", source.path
        ])
        var options = AudioCleanupOptions()
        options.executable = engine
        options.reductionDB = 0
        let low = try await AudioCleanup.preview(source, options: options, start: 0, duration: 0.49)
        #expect(!low.isNearClipping)
        let high = try await AudioCleanup.preview(source, options: options, start: 0.55, duration: 0.3)
        #expect(high.isNearClipping)
        let playback = folder.appending(path: "playback.wav")
        try high.cleaned.write(to: playback)
        #expect(try Self.samples(in: playback).map(abs).max() ?? 1 < 0.99)

        let exported = folder.appending(path: "exported.wav")
        let result = try await AudioCleanup.export(source, to: exported, options: options) { _ in }
        #expect(result.contains("Peaks near clipping"))
        #expect(try Self.samples(in: exported).map(abs).max() ?? 0 > 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func verifiesSilentTrackAndCopiesEncodedPicturePackets() async throws {
        let engine = try Self.executable()
        let folder = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let silent = folder.appending(path: "silent.wav")
        _ = try Self.run(engine, ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "1", silent.path])
        var options = AudioCleanupOptions()
        options.executable = engine
        let rejected = folder.appending(path: "silent-output.wav")
        await #expect(throws: ToolError.self) {
            try await AudioCleanup.export(silent, to: rejected, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))

        let source = folder.appending(path: "video.mp4")
        let output = folder.appending(path: "video.mkv")
        _ = try Self.run(engine, [
            "-f", "lavfi", "-i", "testsrc2=s=64x48:r=24:d=1.25",
            "-f", "lavfi", "-i", "sine=f=440:r=48000:d=1.25",
            "-c:v", "libx264", "-c:a", "aac", source.path
        ])
        options.output = .mkv
        _ = try await AudioCleanup.export(source, to: output, options: options) { _ in }
        let packets = ["-map", "0:v:0", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"]
        #expect(try Self.run(engine, ["-i", source.path] + packets) == Self.run(engine, ["-i", output.path] + packets))
    }

    private static func makeDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private static func executable() throws -> URL {
        URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["-nostdin", "-loglevel", "error"] + arguments
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return data
    }

    private static func samples(in url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?.pointee)
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func rms(_ signal: [Float]) -> Double {
        sqrt(signal.reduce(0.0) { $0 + Double($1 * $1) } / Double(signal.count))
    }

    private static func amplitude(_ signal: [Float], at hertz: Double) -> Double {
        let sampleRate = 48_000
        let start = sampleRate
        let end = min(signal.count, start + sampleRate)
        let period = 2 * .pi * hertz / Double(sampleRate)
        var sine = 0.0
        var cosine = 0.0
        for index in start..<end {
            sine += Double(signal[index]) * sin(period * Double(index))
            cosine += Double(signal[index]) * cos(period * Double(index))
        }
        return hypot(sine, cosine) * 2 / Double(end - start)
    }
}
