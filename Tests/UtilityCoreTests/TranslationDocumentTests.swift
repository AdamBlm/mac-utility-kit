import Foundation
import Testing
import Translation
import UtilityCore

struct TranslationDocumentTests {
    @Test func subRipKeepsIDsOverlapsAndMixedLineEndings() throws {
        let source = "7\r\n00:00:03,200 --> 00:00:05,600\r\nBonjour\r\nTout le monde\r\n\r\n"
            + "9\n00:00:04,000 --> 00:00:07,000\nA bientôt"
        let file = try TranslationDocument(source, kind: .srt)
        #expect(file.requests == ["Bonjour", "Tout le monde", "A bientôt"])
        let result = try file.rendering(["Hello", "Everyone", "See you soon"])
        #expect(result == "7\r\n00:00:03,200 --> 00:00:05,600\r\nHello\r\nEveryone\r\n\r\n"
                + "9\n00:00:04,000 --> 00:00:07,000\nSee you soon")
        let edited = result.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "Everyone", with: "Everybody")
        #expect(try file.applyingEdits(edited) == result.replacingOccurrences(of: "Everyone", with: "Everybody"))
        #expect(throws: ToolError.self) {
            try file.applyingEdits(result.replacingOccurrences(of: "05,600", with: "05,601"))
        }
    }

    @Test func webVTTKeepsTimestampMapSettingsIdentifiersAndMetadata() throws {
        let source = "\u{FEFF}" + """
        WEBVTT Example
        X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:90000

        NOTE preparation notes

        STYLE
        ::cue { color: lime }

        REGION
        id:scrolling

        first cue
        00:01.000 --> 00:04.000 line:0% region:scrolling
        Bonjour
        """
        let file = try TranslationDocument(source, kind: .vtt)
        #expect(file.requests == ["Bonjour"])
        #expect(try file.rendering(["Hello"]) == source.replacingOccurrences(of: "Bonjour", with: "Hello"))
    }

    @Test func rejectsDamagedCuesAndUnsupportedFormatting() throws {
        #expect(throws: ToolError.self) {
            try TranslationDocument("1\n00:00:01,000 --> 00:00:03,000\n<i>Styled cue</i>", kind: .srt)
        }
        #expect(throws: ToolError.self) {
            try TranslationDocument("WEBVTT\n\n00:04.000 --> 00:01.000\nBroken", kind: .vtt)
        }
        let document = try TranslationDocument("1\n00:00:01,000 --> 00:00:03,000\nText", kind: .srt)
        #expect(throws: ToolError.self) { try document.rendering([]) }
        #expect(throws: ToolError.self) { try document.rendering(["text --> another cue"]) }
    }

    @Test func plainTextPreservesParagraphSeparation() throws {
        let document = try TranslationDocument("Bonjour\r\n\r\nA bientôt", kind: .text)
        #expect(document.requests == ["Bonjour", "A bientôt"])
        #expect(try document.rendering(["Hello", "See you soon"]) == "Hello\r\n\r\nSee you soon")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_TRANSLATE_TEST"] == "1"))
    func translatesWithInstalledAppleModel() async throws {
        guard #available(macOS 26.0, *) else { return }
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "fr")
        try #require(await LanguageAvailability().status(from: source, to: target) == .installed)
        let document = try TranslationDocument(
            "1\n00:00:01,000 --> 00:00:03,000\nGood morning", kind: .srt
        )
        let session = TranslationSession(installedSource: source, target: target)
        let output = try await AppleTranslationProvider.translate(document, using: session, source: source, target: target)
        #expect(output.hasPrefix("1\n00:00:01,000 --> 00:00:03,000\n"))
        #expect(output.localizedCaseInsensitiveContains("bonjour"))
    }
}
