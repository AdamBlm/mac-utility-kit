import Testing
import UtilityCore

struct UnicodeInspectorTests {
    @Test func emojiAndCombiningMarksPreserveGraphemesAndBytes() throws {
        let source = "👩‍💻e\u{301}"
        #expect(source.count == 2)
        let emoji = UnicodeInspector.Grapheme(value: try #require(source.first))
        #expect(emoji.scalars.map(\.codePoint) == ["U+1F469", "U+200D", "U+1F4BB"])
        #expect(emoji.scalars[1].invisibleMarker == "JOIN CONTROL")
        #expect(emoji.display == "👩‍💻")
        #expect(emoji.utf8 == "F0 9F 91 A9 E2 80 8D F0 9F 92 BB")

        let accent = UnicodeInspector.Grapheme(value: try #require(source.last))
        #expect(accent.scalars.map(\.codePoint) == ["U+0065", "U+0301"])
        #expect(accent.scalars[1].name == "COMBINING ACUTE ACCENT")
        #expect(accent.scalars[1].category == "nonspacingMark")
        #expect(accent.scalars[1].display == "◌\u{301}")
        #expect(accent.utf8 == "65 CC 81")
    }

    @Test func identifiesInvisibleControlsAndWhitespace() {
        let input = "\u{202E}\u{200B}\u{00A0}\r\n\t "
        let scalars = input.unicodeScalars.map(UnicodeInspector.Scalar.init(value:))
        #expect(scalars.map(\.invisibleMarker) == [
            "BIDI CONTROL", "DEFAULT IGNORABLE", "WHITESPACE", "CR", "LF", "TAB", "SPACE"
        ])
        #expect(scalars.first?.name == "RIGHT-TO-LEFT OVERRIDE")
        #expect(UnicodeInspector.Scalar(value: "A").invisibleMarker == nil)
        #expect(UnicodeInspector.Grapheme(value: "\r\n").display == "[CR][LF]")
    }

    @Test func unicodeDataIncludesSingleAndMultiScalarPrototypes() throws {
        let mapping = try #require(UnicodeInspector.confusables)
        #expect(mapping.count > 5_000)
        #expect(mapping["\u{430}"] == "a")
        #expect(mapping["m"] == "rn")
        #expect(mapping[" "] == nil)
    }

    @Test func canonicalNormalizationChangesBytesOnlyWhenApplied() {
        let input = "Cafe\u{301}"
        let normalized = UnicodeInspector.Normalization.nfc.apply(to: input)
        #expect(input == normalized)
        #expect(!input.utf8.elementsEqual(normalized.utf8))
        #expect(normalized.utf8.elementsEqual("Café".utf8))
        #expect(UnicodeInspector.Normalization.nfd.apply(to: normalized).utf8.elementsEqual(input.utf8))
        #expect(input.unicodeScalars.last?.value == 0x301)
    }
}
