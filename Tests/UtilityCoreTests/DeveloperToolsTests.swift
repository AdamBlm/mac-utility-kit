import Foundation
import Testing
import UtilityCore

@Suite struct JSONFormatterTests {
    @Test func preservesNumbersAndDuplicateKeysWhenSorted() throws {
        let result = try JSONFormatter.format(
            #"{"z": -0, "a":9223372036854775808123, "\u0061":1.000e+400, "n":[true,null,{}]}"#,
            indentation: .minified, sortKeys: true
        )
        #expect(result.text == #"{"a":9223372036854775808123,"\u0061":1.000e+400,"n":[true,null,{}],"z":-0}"#)
        #expect(result.duplicateKeys == ["a"])
    }

    @Test func keepsDistinctUnicodeScalarSequencesInKeys() throws {
        let result = try JSONFormatter.format(#"{"\u00e9":1,"e\u0301":2,"é":3}"#, indentation: .minified)
        #expect(result.duplicateKeys == ["é"])
        #expect(Array(result.text.utf8) == Array(#"{"\u00e9":1,"e\u0301":2,"é":3}"#.utf8))
    }

    @Test func outputsExpectedIndentation() throws {
        let result = try JSONFormatter.format(#"{"a":[1,2]}"#, indentation: .tab)
        #expect(result.text == "{\n\t\"a\": [\n\t\t1,\n\t\t2\n\t]\n}")
    }

    @Test(arguments: ["[01]", "1.", "1e-", "[true,]", "{\"a\":0,}", "{}{}", "\"\\x\"", "\"\\uAAG9\""])
    func rejectsMalformedJSON(_ text: String) {
        #expect(throws: JSONFormatError.self) { try JSONFormatter.format(text) }
    }

    @Test func reportsLineAndColumn() throws {
        do {
            _ = try JSONFormatter.format("{\r\n  \"a\": }")
            Issue.record("Expected a syntax error")
        } catch let error as JSONFormatError {
            #expect(error.line == 2)
            #expect(error.column == 8)
        }
    }
}

@Suite struct ByteEncodingTests {
    @Test func formatsAllEncodings() throws {
        let bytes = Data([0xfb, 0xff])
        #expect(ByteEncoding.base64.encode(bytes) == "+/8=")
        #expect(ByteEncoding.base64URL.encode(bytes, padded: false) == "-_8")
        #expect(ByteEncoding.hex.encode(bytes, wrapAt: 2) == "fb\nff")
        #expect(ByteEncoding.binary.encode(bytes) == "1111101111111111")
        #expect(try ByteEncoding.base64URL.decode(" -_8\n") == bytes)
        #expect(try ByteEncoding.hex.decode("FB ff") == bytes)
    }

    @Test(arguments: ByteEncoding.allCases)
    func roundTripsAllByteValues(_ encoding: ByteEncoding) throws {
        let bytes = Data(UInt8.min...UInt8.max)
        #expect(try encoding.decode(encoding.encode(bytes, padded: false, wrapAt: 76)) == bytes)
        #expect(try encoding.decode("") == Data())
    }

    @Test(arguments: ["Zg=", "Z===", "Zh==", "Z=g=", "Zg=@", "Z", "-_8="])
    func rejectsMalformedStandardBase64(_ text: String) {
        #expect(throws: ByteEncodingError.self) { try ByteEncoding.base64.decode(text) }
    }

    @Test func rejectsInvalidHexAndBinaryDigitsAndPartialBytes() {
        #expect(throws: ByteEncodingError.self) { try ByteEncoding.hex.decode("0") }
        #expect(throws: ByteEncodingError.self) { try ByteEncoding.hex.decode("0x12") }
        #expect(throws: ByteEncodingError.self) { try ByteEncoding.binary.decode("01") }
        #expect(throws: ByteEncodingError.self) { try ByteEncoding.binary.decode("01010102") }
        #expect(throws: ByteEncodingError.self) { try ByteEncoding.base64URL.decode("+/8=") }
    }
}
