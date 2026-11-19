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
            try TranslationDocument("1\n00:00:01,000 --> 00:00:03,000\n<custom>Styled cue</custom>", kind: .srt)
        }
        #expect(throws: ToolError.self) {
            try TranslationDocument("WEBVTT\n\n00:04.000 --> 00:01.000\nBroken", kind: .vtt)
        }
        let document = try TranslationDocument("1\n00:00:01,000 --> 00:00:03,000\nText", kind: .srt)
        #expect(throws: ToolError.self) { try document.rendering([]) }
        #expect(throws: ToolError.self) { try document.rendering(["text --> another cue"]) }
    }

    @Test func subRipPreservesFormattingAndDialogueBoundaries() throws {
        let header = "7\r\n00:00:01,000 --> 00:00:03,000\r\n"
        let source = header + "<FONT color=\"#ffee00\"><I>Bonjour</I> à tous</FONT><br/>Bienvenue\r\n"
        let file = try TranslationDocument(source, kind: .srt)
        #expect(file.requests == ["Bonjour", "à tous", "Bienvenue"])
        let result = try file.rendering(["Hello", "everyone", "Welcome"])
        #expect(result == header + "<FONT color=\"#ffee00\"><I>Hello</I> everyone</FONT><br/>Welcome\r\n")
        let edited = result.replacingOccurrences(of: "everyone", with: "all")
        #expect(try file.applyingEdits(edited.replacingOccurrences(of: "\r\n", with: "\n")) == edited)
        #expect(throws: ToolError.self) {
            try file.applyingEdits(result.replacingOccurrences(of: "<I>Hello</I> everyone", with: "<I></I>Hello everyone"))
        }
        #expect(throws: ToolError.self) {
            try file.applyingEdits(result.replacingOccurrences(of: "#ffee00", with: "#ff0000"))
        }
        #expect(throws: ToolError.self) {
            try file.rendering(["<b>Hello</b>", "everyone", "Welcome"])
        }
        let plain = try TranslationDocument(header + "x < 4", kind: .srt)
        #expect(try plain.rendering(["x < 5"]) == header + "x < 5")
    }

    @Test func webVTTTranslatesAndEditsDialogueWhilePreservingFormatting() throws {
        let header = "WEBVTT\r\n\r\n00:01.000 --> 00:04.000 align:start\r\n"
        let source = header + "<v Narrateur><c.highlight>Bonjour <i>à tous</i></c>\r\n<b>Bienvenue</b></v>\r\n"
        let file = try TranslationDocument(source, kind: .vtt)
        #expect(file.requests == ["Bonjour", "à tous", "Bienvenue"])
        let result = try file.rendering(["Hello", "everyone", "Welcome"])
        #expect(result == header + "<v Narrateur><c.highlight>Hello <i>everyone</i></c>\r\n<b>Welcome</b></v>\r\n")
        let edited = result.replacingOccurrences(of: "everyone", with: "all")
        #expect(try file.applyingEdits(edited.replacingOccurrences(of: "\r\n", with: "\n")) == edited)
        #expect(throws: ToolError.self) {
            try file.applyingEdits(result.replacingOccurrences(of: "highlight", with: "different-class"))
        }
        #expect(throws: ToolError.self) {
            try file.applyingEdits(result.replacingOccurrences(of: "<b>Welcome</b></v>", with: "<b></b></v>Welcome"))
        }
        #expect(throws: ToolError.self) {
            try TranslationDocument(header + "Unsupported <custom>markup</custom>", kind: .vtt)
        }
        #expect(throws: ToolError.self) {
            try TranslationDocument(header + "<lang fr>Bonjour</lang>", kind: .vtt)
        }
    }

    @Test func webVTTDecodesStandardCharacterReferencesAndEscapesTranslatedText() throws {
        let header = "WEBVTT\r\n\r\n00:01.000 --> 00:03.000\r\n"
        let source = header + "<v Sam &amp; Jo><i>Tom &amp; Jane &lt;3 &copy; &#x1F44B; &amp;lt; R&D</i></v>\r\n&nbsp;\r\n"
        let file = try TranslationDocument(source, kind: .vtt)
        #expect(file.requests == ["Tom & Jane <3 © 👋 &lt; R&D"])
        let result = try file.rendering(["Tom & Jane --> <2>"])
        #expect(result == header + "<v Sam &amp; Jo><i>Tom &amp; Jane --&gt; &lt;2&gt;</i></v>\r\n&nbsp;\r\n")
        #expect(try file.applyingEdits(result) == result)
        #expect(throws: ToolError.self) {
            try file.applyingEdits(result.replacingOccurrences(of: "&lt;2&gt;", with: "<b>2</b>"))
        }
        #expect(throws: ToolError.self) {
            try TranslationDocument(header + "Invalid &missing;", kind: .vtt)
        }
        let whitespace = try TranslationDocument(header + "<b>Hello</b>&nbsp;", kind: .vtt)
        #expect(whitespace.requests == ["Hello"])
        #expect(try whitespace.rendering(["Bonjour"]) == header + "<b>Bonjour</b>&nbsp;")
        #expect(throws: ToolError.self) {
            try whitespace.applyingEdits(header + "<b>&nbsp;</b>Bonjour")
        }
    }

    @Test func markdownTranslatesTextWithoutChangingHeadingsListsLinksOrCode() throws {
        let source = """
        ## Étude

        - Une **note** et [ce lien](https://example.test/path "Doc")
        - Lancez `echo bonjour`

        ```sh
        printf 'bonjour'
        ```
        """
        let markdown = try TranslationDocument(source, kind: .markdown)
        #expect(markdown.requests == ["Étude", "Une", "note", "et", "ce lien", "Lancez"])
        let output = try markdown.rendering(["Study", "A", "note", "and", "this link", "Run"])
        #expect(output.contains("## Study"))
        #expect(output.contains("A **note** and [this link](https://example.test/path \"Doc\")"))
        #expect(output.contains("Run `echo bonjour`"))
        #expect(output.contains("printf 'bonjour'"))
        #expect(try markdown.applyingEdits(output.replacingOccurrences(of: "Study", with: "Overview"))
                .contains("## Overview"))
        for changed in [
            output.replacingOccurrences(of: "## Study", with: "# Study"),
            output.replacingOccurrences(of: "https://example.test/path", with: "https://example.test/other"),
            output.replacingOccurrences(of: "echo bonjour", with: "echo hello")
        ] {
            #expect(throws: ToolError.self) { try markdown.applyingEdits(changed) }
        }
    }

    @Test func markdownTranslatesImageDescriptionsButKeepsAssetTitlesAndAddresses() throws {
        let markdown = try TranslationDocument(
            "## Image\r\n\r\n![Petit chat](images/chat.png \"Asset title\")\r\n\r\n<https://example.test>", kind: .markdown
        )
        #expect(markdown.requests == ["Image", "Petit chat"])
        let output = try markdown.rendering(["Picture", "Small cat"])
        #expect(output.contains("![Small cat](images/chat.png \"Asset title\")"))
        #expect(output.contains("<https://example.test>"))
        #expect(!output.contains("\r"))
    }

    @Test func markdownEscapesTranslatedPunctuationAndRejectsUnsupportedStructures() throws {
        let markdown = try TranslationDocument("Bonjour", kind: .markdown)
        let output = try markdown.rendering(["<b>Hello</b> and **literal**"])
        #expect(try TranslationDocument(output, kind: .markdown).requests == ["<b>Hello</b> and **literal**"])
        #expect(throws: ToolError.self) {
            try TranslationDocument("| A | B |\n| - | - |\n| C | D |", kind: .markdown)
        }
        for unsupported in ["Bonjour <b>monde</b>", "- [x] Bonjour", "~~Bonjour~~", "Bonjour[^a]\n\n[^a]: Note.",
                            "\u{FEFF}---\r\ntitle: Bonjour\r\n---\r\n\r\nTexte", "+++\ntitle = 'Bonjour'\n+++\n\nTexte"] {
            #expect(throws: ToolError.self) { try TranslationDocument(unsupported, kind: .markdown) }
        }
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

        let webVTT = try TranslationDocument(
            "WEBVTT\n\n00:01.000 --> 00:03.000\n<v Narrator><b>Good morning</b></v>\n",
            kind: .vtt
        )
        let formatted = try await AppleTranslationProvider.translate(webVTT, using: session, source: source, target: target)
        #expect(formatted.hasPrefix("WEBVTT\n\n00:01.000 --> 00:03.000\n<v Narrator><b>"))
        #expect(formatted.hasSuffix("</b></v>\n"))
        #expect(formatted.localizedCaseInsensitiveContains("bonjour"))

        let markdown = try TranslationDocument("# Good morning\n\n[Good morning](https://example.test)", kind: .markdown)
        let translatedMarkdown = try await AppleTranslationProvider.translate(markdown, using: session, source: source, target: target)
        #expect(translatedMarkdown.hasPrefix("# "))
        #expect(translatedMarkdown.localizedCaseInsensitiveContains("bonjour"))
        #expect(translatedMarkdown.contains("](https://example.test)"))
    }
}
