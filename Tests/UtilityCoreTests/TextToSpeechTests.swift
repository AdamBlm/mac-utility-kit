import AVFoundation
import CoreText
import Testing
@testable import UtilityCore

@Suite(.serialized)
struct TextToSpeechTests {
    @Test func automaticVoiceDetectsFrenchWithAnInstalledFrenchVoice() {
        let passage = "Ce matin, je suis allé au marché pour acheter des pommes et des poires. "
            + "Ensuite, je suis rentré préparer le déjeuner avec ma famille et discuter de nos vacances."
        let preferred = SpeechLanguageSelection.installedLanguage(
            for: passage, currentLanguage: "en-US", available: ["en-US", "fr-FR"]
        )
        #expect(preferred == "fr-FR")
    }

    @Test func automaticVoiceKeepsLocaleForShortAmbiguousOrUnsupportedInput() {
        let passage = "A paragraph long enough to identify the usual language."
        #expect(SpeechLanguageSelection.installedLanguage(
            for: "Bonjour", currentLanguage: "en-US", available: ["fr-FR"], identify: { _ in ["fr": 1] }
        ) == nil)
        #expect(SpeechLanguageSelection.installedLanguage(
            for: passage, currentLanguage: "en-US", available: ["fr-FR"], identify: { _ in ["fr": 0.66, "en": 0.34] }
        ) == nil)
        #expect(SpeechLanguageSelection.installedLanguage(
            for: passage, currentLanguage: "en-US", available: ["en-US"], identify: { _ in ["fr": 1] }
        ) == nil)
    }

    @Test func automaticVoiceMatchesScriptAndPrefersTheCurrentRegionWhenCompatible() {
        let passage = "A paragraph long enough to identify the usual language."
        #expect(SpeechLanguageSelection.installedLanguage(
            for: passage, currentLanguage: "zh-CN", available: ["zh-CN", "zh-TW"], identify: { _ in ["zh-Hant": 1] }
        ) == "zh-TW")
        #expect(SpeechLanguageSelection.installedLanguage(
            for: passage, currentLanguage: "en-GB", available: ["en-US", "en-GB"], identify: { _ in ["en": 1] }
        ) == "en-GB")
    }

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

    @Test func opensPasswordProtectedPDFPagesForSpeechAndHonorsCopyRestrictions() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let readable = folder.appending(path: "Protected.pdf")
        let restricted = folder.appending(path: "Protected Copy Restricted.pdf")
        let password = "test-reader"
        let security: [String: Any] = [
            kCGPDFContextUserPassword as String: password,
            kCGPDFContextOwnerPassword as String: "test-owner",
            kCGPDFContextAllowsCopying as String: true
        ]
        try Self.makePDF(at: readable, pages: ["First section", "Second section"], options: security)
        await #expect(throws: ToolError.self) { try await SpeechDocument.loadForSpeech(readable, pages: "2") }
        await #expect(throws: ToolError.self) {
            try await SpeechDocument.loadForSpeech(readable, pages: "2", password: "invalid")
        }
        #expect(try await SpeechDocument.loadForSpeech(readable, pages: "2", password: password) == "Second section")

        var restrictedSecurity = security
        restrictedSecurity[kCGPDFContextAllowsCopying as String] = false
        try Self.makePDF(at: restricted, options: restrictedSecurity)
        await #expect(throws: ToolError.self) {
            try await SpeechDocument.loadForSpeech(restricted, pages: "", password: password)
        }
    }

    @Test func recognizesScanTextAlongsideEmbeddedTextOnlyOnSelectedPDFPages() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appending(path: "Mixed PDF.pdf")
        let bounds = CGRect(x: 0, y: 0, width: 450, height: 160)
        var mediaBox = bounds
        let document = try #require(CGContext(pdf as CFURL, mediaBox: &mediaBox, nil))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let scan = try #require(CGContext(data: nil, width: 900, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        ]
        scan.setFillColor(CGColor(gray: 1, alpha: 1))
        scan.fill(CGRect(x: 0, y: 0, width: 900, height: 120))
        scan.textPosition = CGPoint(x: 40, y: 45)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Scanned checklist", attributes: attributes)), scan)
        let scanImage = try #require(scan.makeImage())
        for (index, text) in ["Outside selection", "Digital heading", ""].enumerated() {
            document.beginPDFPage(nil)
            document.textPosition = CGPoint(x: 20, y: 40)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), document)
            if index > 0 {
                document.draw(scanImage, in: CGRect(x: 0, y: 90, width: bounds.width, height: 60))
            }
            document.endPDFPage()
        }
        document.closePDF()

        #expect(try await SpeechDocument.loadForSpeech(pdf, pages: "2") == "Digital heading")
        await #expect(throws: ToolError.self) { try await SpeechDocument.loadForSpeech(pdf, pages: "3") }
        let mixed = try await SpeechDocument.loadForSpeech(pdf, pages: "2", password: "", recognizesScans: true)
        #expect(mixed.components(separatedBy: "Digital heading").count == 2)
        #expect(mixed.contains("Scanned checklist"))
        #expect(!mixed.contains("Outside selection"))
        let scanned = try await SpeechDocument.loadForSpeech(pdf, pages: "3", password: "", recognizesScans: true)
        #expect(scanned == "Scanned checklist")
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

    private static func makePDF(
        at url: URL, pages: [String] = ["Readable text"], options: [String: Any] = [:]
    ) throws {
        var rectangle = CGRect(x: 0, y: 0, width: 250, height: 100)
        let context = try #require(CGContext(url as CFURL, mediaBox: &rectangle, options as CFDictionary))
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
