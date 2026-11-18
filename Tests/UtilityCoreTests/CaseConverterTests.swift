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
}
