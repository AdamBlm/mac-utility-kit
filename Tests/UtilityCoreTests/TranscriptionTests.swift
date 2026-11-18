import AVFoundation
import Foundation
import Testing
@testable import UtilityCore

@Suite struct TranscriptionTests {
    @Test func exportsSourceTimecodesWithEditedText() throws {
        let json = Data("""
        {"result":{"language":"fr"},"transcription":[
            {"offsets":{"from":0,"to":750},"text":"  <voix> & texte  "},
            {"offsets":{"from":800,"to":1500},"text":"Autre segment"}
        ]}
        """.utf8)
        let cues = try Transcription.parseWhisperJSON(json, sourceOffset: 12.5, duration: 1.45, language: "fr")
        #expect(cues.map(\.startMilliseconds) == [12_500, 13_300])
        #expect(cues.map(\.endMilliseconds) == [13_250, 13_950])
        #expect(try SubRip.parse(Transcription.render(cues, format: .srt)) == cues)
        #expect(Transcription.render(cues, format: .txt) == "<voix> & texte\nAutre segment\n")
        let vtt = Transcription.render(cues, format: .vtt)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:12.500 --> 00:00:13.250\n&lt;voix&gt; &amp; texte"))
        #expect(throws: ToolError.self) {
            try Transcription.parseWhisperJSON(json, sourceOffset: 12.5, duration: 1.45, language: "en")
        }
    }

    @Test func rejectsOverlappingWhisperTimestamps() {
        let json = Data("""
        {"transcription":[{"offsets":{"from":0,"to":1000},"text":"first"},
                          {"offsets":{"from":500,"to":1500},"text":"overlap"}]}
        """.utf8)
        #expect(throws: ToolError.self) {
            try Transcription.parseWhisperJSON(json, sourceOffset: 2, duration: 2, language: "auto")
        }
    }

    @Test func normalizesSelectedStereoAudioAndAddsSourceOffset() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("stereo.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames: AVAudioFrameCount = 48_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            channels[0][frame] = 0.1 * sin(Float(frame) / 20)
            channels[1][frame] = 0.2 * sin(Float(frame) / 20)
        }
        try writeWave(buffer, to: source)
        let engine = try mockEngine(in: folder)
        var options = TranscriptionOptions()
        options.executable = engine.0
        options.model = engine.1
        options.start = 0.2
        options.end = 0.65
        let transcript = try await Transcription.runWithLanguage(source, options: options) { _ in }
        #expect(transcript.language == "en")
        #expect(!transcript.forcedEnglish)
        #expect(transcript.cues == [SubtitleCue(startMilliseconds: 300, endMilliseconds: 500, text: "Fixture speech")])
        let normalized = try AVAudioFile(forReading: folder.appendingPathComponent("observed.wav"))
        #expect(normalized.fileFormat.sampleRate == 16_000)
        #expect(normalized.fileFormat.channelCount == 1)
        #expect(normalized.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
        #expect(abs(Double(normalized.length) / 16_000 - 0.45) < 0.03)
        let samples = try #require(AVAudioPCMBuffer(pcmFormat: normalized.processingFormat, frameCapacity: 500))
        try normalized.read(into: samples)
        let wave = try #require(samples.floatChannelData?.pointee)
        #expect((0..<Int(samples.frameLength)).contains { abs(wave[$0]) > 0.05 })
    }

    @Test func distinguishesModelLanguageCapabilitiesFromHeader() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = try mockEngine(in: folder)
        func writeVocabulary(_ count: UInt32) throws {
            let header = [UInt32(0x67676d6c).littleEndian, count.littleEndian]
            try header.withUnsafeBytes { try Data($0).write(to: engine.1) }
        }
        #expect(try Transcription.modelCapability(at: engine.1) == .unknown)
        try writeVocabulary(50_000)
        #expect(try Transcription.modelCapability(at: engine.1) == .unknown)
        try writeVocabulary(51_865)
        #expect(try Transcription.modelCapability(at: engine.1) == .multilingual)
        try writeVocabulary(51_864)
        #expect(try Transcription.modelCapability(at: engine.1) == .englishOnly)

        let source = folder.appendingPathComponent("test.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try #require(buffer.floatChannelData?.pointee)
        for index in 0..<8_000 { samples[index] = 0 }
        try writeWave(buffer, to: source)

        var options = TranscriptionOptions()
        options.executable = engine.0
        options.model = engine.1
        options.language = "fr"
        await #expect(throws: ToolError.self) {
            try await Transcription.runWithLanguage(source, options: options) { _ in }
        }
        let observed = folder.appendingPathComponent("observed.wav")
        #expect(!FileManager.default.fileExists(atPath: observed.path))
        options.language = "auto"
        let result = try await Transcription.runWithLanguage(source, options: options) { _ in }
        #expect(result.language == "en")
        #expect(result.forcedEnglish)
        #expect(try String(contentsOf: folder.appendingPathComponent("observed-language"), encoding: .utf8) == "en")
    }

    @Test func reportsVideoWithoutAudioBeforeRunningWhisper() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await conversionFixture(in: folder)
        let engine = try mockEngine(in: folder)
        var options = TranscriptionOptions()
        options.executable = engine.0
        options.model = engine.1
        await #expect(throws: ToolError.self) {
            try await Transcription.run(source, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("observed.wav").path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_WHISPER_TEST"] != nil &&
                   ProcessInfo.processInfo.environment["MAC_UTILITY_WHISPER_MODEL_TEST"] != nil &&
                   ProcessInfo.processInfo.environment["MAC_UTILITY_WHISPER_AUDIO_TEST"] != nil))
    func transcribesUpstreamLocalWhisperFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        var options = TranscriptionOptions()
        options.executable = URL(fileURLWithPath: try #require(env["MAC_UTILITY_WHISPER_TEST"]))
        options.model = URL(fileURLWithPath: try #require(env["MAC_UTILITY_WHISPER_MODEL_TEST"]))
        let audio = URL(fileURLWithPath: try #require(env["MAC_UTILITY_WHISPER_AUDIO_TEST"]))
        let result = try await Transcription.runWithLanguage(audio, options: options) { _ in }
        let cues = result.cues
        #expect(result.language == "en")
        if let model = options.model, try Transcription.modelCapability(at: model) == .englishOnly {
            #expect(result.forcedEnglish)
        }
        #expect(!cues.isEmpty)
        #expect(Transcription.render(cues, format: .txt).lowercased().contains("country"))
        #expect(try SubRip.parse(Transcription.render(cues, format: .srt)) == cues)
    }

    private func writeWave(_ buffer: AVAudioPCMBuffer, to output: URL) throws {
        let file = try AVAudioFile(forWriting: output, settings: buffer.format.settings)
        try file.write(from: buffer)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func mockEngine(in folder: URL) throws -> (URL, URL) {
        let executable = folder.appendingPathComponent("whisper-cli")
        let model = folder.appendingPathComponent("fixture-model.bin")
        let script = """
        #!/bin/sh
        set -eu
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -f) wave="$2"; shift ;;
            -l) language="$2"; shift ;;
                -of) out="$2"; shift ;;
            esac
            shift
        done
        /bin/cp "$wave" "$(dirname "$0")/observed.wav"
        printf '%s' "$language" > "$(dirname "$0")/observed-language"
        cat > "$out.json" <<'JSON'
        {"result":{"language":"en"},"transcription":[{"offsets":{"from":100,"to":300},"text":" Fixture speech "}]}
        JSON
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data().write(to: model)
        return (executable, model)
    }
}
