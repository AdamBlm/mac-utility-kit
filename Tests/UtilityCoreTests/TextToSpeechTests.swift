import AVFoundation
import CoreText
import Testing
@testable import UtilityCore

@Suite(.serialized)
struct TextToSpeechTests {
    @Test
    @MainActor
    func rejectsInvalidSpeechRequestsAndUnknownVoices() async {
        await #expect(throws: ToolError.self) { try await TextToSpeech.render(.init(text: "  ")) }
        await #expect(throws: ToolError.self) {
            try await TextToSpeech.render(.init(text: "Hello", voiceID: "unavailable.invalid.voice"))
        }
        await #expect(throws: ToolError.self) { try await TextToSpeech.render(.init(text: "Hello", rate: .nan)) }
    }

    @Test
    func importsUnicodeTextRichTextAndPDFTextLayer() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appending(path: "words.txt")
        let rtf = folder.appending(path: "rich.rtf")
        let pdf = folder.appending(path: "document.pdf")
        try #require("Bonjour café".data(using: .utf16)).write(to: plain)
        try Data("{\\rtf1\\ansi Rich \\b text\\b0 .}".utf8).write(to: rtf)
        try Self.makePDF(at: pdf)
        #expect(try await SpeechDocument.load(plain) == "Bonjour café")
        #expect(try await SpeechDocument.load(rtf).contains("Rich text"))
        #expect(try await SpeechDocument.load(pdf).contains("Readable text"))
    }

    @Test func loadsOnlyRequestedPDFPagesForSpeech() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appending(path: "Sections.pdf")
        try Self.makePDF(at: pdf, pages: ["First section", "Middle section", "Last section"])
        #expect(try await SpeechDocument.loadForSpeech(pdf, pages: "3, 2, 2") == "Middle section\n\nLast section")
        for invalid in ["none", "0", "4", "one"] {
            await #expect(throws: ToolError.self) { try await SpeechDocument.loadForSpeech(pdf, pages: invalid) }
        }
    }

    @Test func importsReadableMarkdownContentForSpeech() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let markdown = folder.appending(path: "talk.markdown")
        let source = """
        # Café talk

        **Welcome**, [reader](https://example.invalid/private).
        This line continues with &amp; and an image ![description](photo.png).

        1. First item
        2. Second item

        <!-- Hidden note -->

        ~~~swift
        print("Hello")
        ~~~
        """
        try Data(source.utf8).write(to: markdown)
        #expect(try await SpeechDocument.load(markdown) == source)
        #expect(try await SpeechDocument.loadForSpeech(markdown) == """
        Café talk

        Welcome, reader. This line continues with & and an image description.

        First item

        Second item

        print("Hello")
        """)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_SPEECH_TEST"] != nil))
    @MainActor
    func nativeVoiceProducesPlayableWaveAndUsesRequestedText() async throws {
        let voice = try #require(TextToSpeech.voices().first { $0.name == "Samantha" && $0.language == "en-US" })
        let sentence = "This sentence should be spoken."
        let selected = try await TextToSpeech.render(.init(text: sentence, voiceID: voice.id))
        let long = try await TextToSpeech.render(.init(text: Array(repeating: sentence, count: 3).joined(separator: " "), voiceID: voice.id))
        #expect(selected.duration > 0.5)
        #expect(long.duration > selected.duration * 2)
        #expect(selected.wave.starts(with: [82, 73, 70, 70]))
        let player = try AVAudioPlayer(data: selected.wave)
        #expect(abs(player.duration - selected.duration) < 0.01)
    }

    @Test func exportsSpeechWaveAsNativeAACWithoutChangingTheWAV() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = 22_050
        let samples = try #require(buffer.floatChannelData?.pointee)
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0.3 * sin(Float(index) / 10) }
        let pcm = try AVAudioFile(forWriting: source, settings: format.settings)
        try pcm.write(from: buffer)
        pcm.close()
        let audio = TextToSpeechAudio(wave: try Data(contentsOf: source), duration: 1)
        #expect(try await audio.encoded(as: .wav) == audio.wave)
        let encoded = try await audio.encoded(as: .m4a)
        let output = folder.appending(path: "export.m4a")
        try encoded.write(to: output)
        let track = try AVAudioFile(forReading: output)
        let readFormat = track.fileFormat
        #expect(readFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(readFormat.channelCount == 1)
        #expect(abs(Double(track.length) / readFormat.sampleRate - 1) < 0.15)
        #expect(encoded.count < audio.wave.count)
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private static func makePDF(at url: URL, pages: [String] = ["Readable text"]) throws {
        var rectangle = CGRect(x: 0, y: 0, width: 250, height: 100)
        let context = try #require(CGContext(url as CFURL, mediaBox: &rectangle, nil))
        for page in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 30)
            let text = NSAttributedString(string: page, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
