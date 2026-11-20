import Foundation
import Testing
@testable import UtilityCore

@Suite struct JSONFormatterTests {
    @Test func capsPrettyOutputInUTF8BytesAndKeepsMinifiedSourceLexemes() throws {
        let source = #"{"é":[9007199254740993, -0.000E+100],"é":[]}"#
        let pretty = try JSONFormatter.format(source, indentation: .fourSpaces)
        let budget = pretty.text.utf8.count
        let exact = try JSONFormatter.format(source, indentation: .fourSpaces, maximumOutputBytes: budget)
        #expect(exact.text == pretty.text)
        #expect(exact.duplicateKeys == ["é"])
        let failure = #expect(throws: ToolError.self) {
            try JSONFormatter.format(source, indentation: .fourSpaces, maximumOutputBytes: budget - 1)
        }
        #expect(failure?.localizedDescription.contains("Choose Minified") == true)
        let compact = try JSONFormatter.format(source, indentation: .minified, maximumOutputBytes: budget - 1)
        #expect(compact.text == #"{"é":[9007199254740993,-0.000E+100],"é":[]}"#)
    }

    @Test func opensBoundedUTF8WithoutChangingJSONTokens() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "input.json")
        let text = "{\"n\":9007199254740993,\"s\":\"e\u{301}\"}"
        try Data(("\u{FEFF}" + text).utf8).write(to: file)
        let input = try await JSONFormatter.loadUTF8(file)
        #expect(input.utf8.elementsEqual(text.utf8))
        #expect(try JSONFormatter.format(input, indentation: .minified).text.utf8.elementsEqual(text.utf8))
        try Data([0xFF]).write(to: file)
        await #expect(throws: ToolError.self) { try await JSONFormatter.loadUTF8(file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(JSONFormatter.maximumInputBytes) + 1)
        try handle.close()
        let oversized = await #expect(throws: ToolError.self) { try await JSONFormatter.loadUTF8(file) }
        #expect(oversized?.localizedDescription.contains("16 MiB") == true)
        let pasted = String(repeating: " ", count: JSONFormatter.maximumInputBytes + 1)
        #expect(throws: ToolError.self) { try JSONFormatter.format(pasted) }
    }

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

    @Test func identifiesRepeatedKeysAtTheirOriginalLocations() throws {
        let input = "{\r\n"
            + #"  "nested":[{"👩‍👩‍👧‍👦":0,"a":1,"a":2}],"# + "\r"
            + #"  "other":{"a":3,"# + "\n"
            + #"     "\u0061":4,"a":5}}"#
        let formatted = try JSONFormatter.format(input, indentation: .minified, sortKeys: true)
        #expect(formatted.duplicateOccurrences.map(\.key) == ["a", "a", "a"])
        #expect(formatted.duplicateOccurrences.map(\.line) == [2, 4, 4])
        #expect(formatted.duplicateOccurrences.map(\.column) == [26, 6, 17])
        #expect(formatted.text.contains(#""a":1,"a":2"#))
        #expect(formatted.text.contains(#""a":3,"\u0061":4,"a":5"#))
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

    @Test func selectsSourceErrorAcrossCRLFUnicodeAndEndOfInput() throws {
        let input = "{\r\n  \"👩‍👩‍👧‍👦\": #}"
        let error = try #require(#expect(throws: JSONFormatError.self) { try JSONFormatter.format(input) })
        let marker = try #require(error.sourceRange(in: input))
        #expect(input[marker] == "#")
        #expect(error.line == 2 && error.column == 8)
        let unclosed = "{\"a\": "
        let endError = try #require(#expect(throws: JSONFormatError.self) { try JSONFormatter.format(unclosed) })
        #expect(endError.sourceRange(in: unclosed) == unclosed.endIndex..<unclosed.endIndex)

        let incompleteGrapheme = "1\u{301}"
        let interior = try #require(#expect(throws: JSONFormatError.self) { try JSONFormatter.format(incompleteGrapheme) })
        let selection = try #require(interior.sourceRange(in: incompleteGrapheme))
        #expect(incompleteGrapheme[selection].utf8.elementsEqual(incompleteGrapheme.utf8))
    }
}

@Suite struct ByteEncodingTests {
    @Test(arguments: ByteEncoding.allCases, [false, true])
    func fileConversionMatchesInMemoryAcrossChunks(format: ByteEncoding, padded: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "input")
        let encoded = folder.appending(path: "encoded")
        let decoded = folder.appending(path: "decoded")
        let data = Data((0..<130_001).map { UInt8(truncatingIfNeeded: $0 * 113) })
        try data.write(to: source)
        try Data("previous output".utf8).write(to: encoded)
        try await format.convertFile(source, to: encoded, decoding: false, padded: padded, wrapAt: 76)
        #expect(try Data(contentsOf: encoded) == Data(format.encode(data, padded: padded, wrapAt: 76).utf8))
        try await format.convertFile(encoded, to: decoded, decoding: true, padded: padded, wrapAt: 0)
        #expect(try Data(contentsOf: decoded) == data)
    }

    @Test func invalidStreamAndCancellationPreserveExistingDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "invalid")
        let output = folder.appending(path: "existing")
        let original = Data("keep me".utf8)
        try original.write(to: output)
        try Data((String(repeating: "YWJj", count: 16_384) + "ZA==x").utf8).write(to: source)
        await #expect(throws: ByteEncodingError.self) {
            try await ByteEncoding.base64.convertFile(source, to: output, decoding: true, padded: true, wrapAt: 0)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ByteEncoding.base64.convertFile(source, to: output, decoding: false, padded: true, wrapAt: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: output) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["existing", "invalid"])
        let alias = folder.appending(path: "input-alias")
        try FileManager.default.linkItem(at: source, to: alias)
        await #expect(throws: ToolError.self) {
            try await ByteEncoding.hex.convertFile(source, to: alias, decoding: false, padded: true, wrapAt: 0)
        }
        #expect(try Data(contentsOf: alias) == Data(contentsOf: source))
    }

    @Test(arguments: [
        (ByteEncoding.base64, "YWJj \n_"),
        (.base64URL, "YWJj \n+"),
        (.hex, "abcd \né"),
        (.binary, "0101 \n2")
    ])
    func locatesInvalidAlphabetByteInOriginalText(format: ByteEncoding, text: String) {
        let error = #expect(throws: ByteEncodingError.self) { try format.decode(text) }
        guard case .invalidCharacterAt(byte: 7)? = error else {
            Issue.record("Expected the invalid alphabet byte at its original offset.")
            return
        }
    }

    @Test func locatesInvalidFileByteAfterWhitespaceAndChunkBoundaries() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "input")
        let output = folder.appending(path: "output")
        let prefix = Data(String(repeating: "YWJj", count: 16_384).utf8)
        let shortError = #expect(throws: ByteEncodingError.self) {
            try ByteEncoding.base64.decode(bytes: Data([13, 10, 9, 0xFF]))
        }
        guard case .invalidCharacterAt(byte: 4)? = shortError else {
            Issue.record("Expected the invalid raw byte in a small input.")
            return
        }
        try (prefix + Data([13, 10, 9, 0xFF])).write(to: source)
        let error = await #expect(throws: ByteEncodingError.self) {
            try await ByteEncoding.base64.convertFile(source, to: output, decoding: true, padded: true, wrapAt: 0)
        }
        guard case .invalidCharacterAt(byte: 65_540)? = error else {
            Issue.record("Expected the invalid raw byte after the first chunk.")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

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
