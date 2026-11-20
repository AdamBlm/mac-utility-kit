import Foundation
import Testing
import UtilityCore

struct CaseConverterTests {
    @Test func transformsUnicodeIdentifiersAcrossAcronymsAndDelimiters() throws {
        let input = "  XMLHTTPRequest—caféUser_ID42 "
        #expect(try CaseConverter.convert(input, to: .snake) == "xmlhttp_request_café_user_id42")
        #expect(try CaseConverter.convert(input, to: .camel) == "xmlhttpRequestCaféUserId42")
        #expect(try CaseConverter.convert("helloWorld—Grüße", to: .kebab) == "hello-world-grüße")
    }

    @Test func preservesCamelCaseBoundariesBeforeNumberLeadingWords() throws {
        let turkish = Locale(identifier: "tr")
        #expect(try CaseConverter.convert("Version 1-2", to: .camel) == "version_1_2")
        #expect(try CaseConverter.convert("Version12", to: .camel) == "version12")
        let input = "Istanbul—42—İş_ID2"
        let identifier = try CaseConverter.convert(input, to: .camel, locale: turkish)
        #expect(identifier == "ıstanbul_42İşId2")
        #expect(try CaseConverter.convert(identifier, to: .camel, locale: turkish) == identifier)
    }

    @Test func respectsLocaleAndPreservesUnselectedLinesAndBreaks() throws {
        let input = "first\r\niş\r\nlast\n"
        let turkish = Locale(identifier: "tr")
        #expect(try CaseConverter.convert(input, to: .uppercase, locale: turkish, selectedLines: "2") == "first\r\nİŞ\r\nlast\n")
        #expect(try CaseConverter.convert("I İ", to: .lowercase, locale: turkish) == "ı i")
        #expect(throws: ToolError.self) { try CaseConverter.convert(input, to: .uppercase, selectedLines: "10") }
    }

    @Test func capitalizesSentencesWithoutRemovingPunctuation() throws {
        #expect(try CaseConverter.convert("ΟΣ.", to: .sentence, locale: Locale(identifier: "el")) == "Ος.")
        let text = "HELLO! «WORLD?»  NEXT."
        #expect(try CaseConverter.convert(text, to: .sentence, locale: Locale(identifier: "en")) == "Hello! «World?»  Next.")
    }

    @Test func convertsHighlightedLinesWithoutIncludingTheEndBoundary() throws {
        let input = "👋 first\r\nkeep\riş\u{2028}last\n"
        let keep = try #require(input.range(of: "keep"))
        let regional = try #require(input.range(of: "ş"))
        let last = try #require(input.range(of: "last"))
        let firstLine = input.startIndex..<keep.lowerBound
        let identifier = try CaseConverter.lineSelection(
            in: input, for: [regional, firstLine, last.upperBound..<last.upperBound]
        )
        #expect(identifier == "1, 3")
        #expect(try CaseConverter.convert(input, to: .uppercase, locale: Locale(identifier: "tr"), selectedLines: identifier)
                == "👋 FİRST\r\nkeep\rİŞ\u{2028}last\n")
        #expect(try CaseConverter.lineSelection(in: input, for: [keep.lowerBound..<last.lowerBound]) == "2–3")
        #expect(try CaseConverter.lineSelection(in: input, for: [last.upperBound..<last.upperBound]).isEmpty)
    }
}
