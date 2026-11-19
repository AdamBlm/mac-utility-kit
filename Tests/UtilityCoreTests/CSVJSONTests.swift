import Foundation
import Testing
import UtilityCore

struct CSVJSONTests {
    @Test func detectsOnlyConsistentUnambiguousDelimitersOutsideQuotedFields() throws {
        let quoted = "\u{FEFF}name,comment\r\nAda,\"contains ; and |\r\nand \"\"quotes\"\"\"\r\nLin,normal"
        #expect(try CSVJSON.detectDelimiter(quoted) == .detected(.comma))
        #expect(try CSVJSON.detectDelimiter("name;price\nAda;1,50\nLin;2,00") == .detected(.semicolon))
        #expect(try CSVJSON.detectDelimiter("name\tcity\nAda\tParis") == .detected(.tab))
        #expect(try CSVJSON.detectDelimiter("name|city\nAda|Paris") == .detected(.pipe))
        #expect(try CSVJSON.detectDelimiter("name,price;unit\nAda,1;each") == .ambiguous([.comma, .semicolon]))
        #expect(try CSVJSON.detectDelimiter("only,a,header") == .unavailable)
        #expect(try CSVJSON.detectDelimiter("name,city\nAda,Paris,France") == .unavailable)
        #expect(try CSVJSON.detectDelimiter("name,city\nAda,\"Paris") == .unavailable)
    }

    @Test func preservesLeadingBOMCharacterInDataAndHeaders() throws {
        let name = "\u{FEFF}name"
        let cases = [
            (#"[["\uFEFFname","value"]]"#, false, [name, "value"]),
            (#"[{"\uFEFFname":"value"}]"#, true, [name])
        ]
        for (input, includesHeader, expectedFirstRow) in cases {
            let csv = try CSVJSON.convert(input, direction: .jsonToCSV, includesHeader: includesHeader)
            #expect(csv.output.utf8.first == 34)
            for prefix in ["", "\u{FEFF}"] {
                let imported = try CSVJSON.convert(
                    prefix + csv.output, direction: .csvToJSON, includesHeader: includesHeader
                )
                let firstRow = includesHeader ? imported.columns : imported.rows.first
                #expect(firstRow == expectedFirstRow)
            }
        }
    }

    @Test func csvDecodesAndRoundTripsQuotedUnicodeAndEmptyFields() throws {
        let input = "\u{FEFF}code,note,tail\r\n001,\"é,\"\"🙂\"\"\r\npart\","
        let json = try CSVJSON.convert(input, direction: .csvToJSON)
        #expect(json.columns == ["code", "note", "tail"])
        #expect(json.rows == [["001", "é,\"🙂\"\r\npart", ""]])
        let decoded = try JSONDecoder().decode([[String: String]].self, from: Data(json.output.utf8))
        #expect(decoded.first?["code"] == "001")
        #expect(decoded.first?["tail"] == "")
        let csv = try CSVJSON.convert(json.output, direction: .jsonToCSV)
        #expect(csv.output == "code,note,tail\r\n001,\"é,\"\"🙂\"\"\r\npart\",\"\"\r\n")
    }

    @Test func preservesSingleEmptyRecordAndValidatesWidths() throws {
        let json = try CSVJSON.convert("\"\"", direction: .csvToJSON, includesHeader: false)
        #expect(json.rows == [[""]])
        let csv = try CSVJSON.convert(json.output, direction: .jsonToCSV, includesHeader: false)
        #expect(csv.output == "\"\"\r\n")
        #expect(try CSVJSON.convert("a,b\n1,", direction: .csvToJSON).rows == [["1", ""]])
        #expect(try CSVJSON.convert("a\n\nb", direction: .csvToJSON, includesHeader: false).rows == [["a"], [""], ["b"]])
        expectIssue("a,b\none", direction: .csvToJSON, contains: "Row 2 has 1 fields")
        expectIssue("a,b\none,\"unfinished", direction: .csvToJSON, contains: "row 2, field 2")
        expectIssue("a,b\none,\"closed\"oops", direction: .csvToJSON, contains: "row 2, field 2")
        expectIssue("a,a\n1,2", direction: .csvToJSON, contains: "Duplicate header")
    }

    @Test func supportsCustomDelimitersAndGFMCellEscapes() throws {
        let input = "first;second\n\"a|b\";\"<x>&*z*\nrow\""
        let markdown = try CSVJSON.convert(input, direction: .csvToMarkdown, delimiter: .semicolon)
        #expect(markdown.output == "| first | second |\n| --- | --- |\n| a&#124;b | &#60;x&#62;&#38;&#42;z&#42;&#10;row |\n")
        let markedPipe = try CSVJSON.convert("label\n|\u{301}", direction: .csvToMarkdown)
        #expect(markedPipe.output.contains("&#124;\u{301}"))
        let tabular = try CSVJSON.convert("x\t\"a\tb\"", direction: .csvToJSON, delimiter: .tab, includesHeader: false)
        #expect(tabular.rows == [["x", "a\tb"]])
        #expect(try CSVJSON.convert(tabular.output, direction: .jsonToCSV, delimiter: .pipe,
                                    includesHeader: false).output == "x|a\tb\r\n")
    }

    @Test func jsonPreservesNumberLexemesAndHeaderOrder() throws {
        let input = """
        [{"z":1234567890123456789012345678901234567890,"a":null},
         {"a":true,"z":1e-1234}]
        """
        let result = try CSVJSON.convert(input, direction: .jsonToCSV)
        #expect(result.output == "z,a\r\n1234567890123456789012345678901234567890,\"\"\r\n1e-1234,true\r\n")
        expectIssue("[{\"col\":1},{\"col\":{}}]", direction: .jsonToCSV, contains: "row 2, field \"col\"")
        expectIssue("[{\"col\":1,\"col\":2}]", direction: .jsonToCSV, contains: "Duplicate field")
        expectIssue("[{\"col\":1},{}]", direction: .jsonToCSV, contains: "row 2 is missing field")
        expectIssue("[[1,2],[3]]", direction: .jsonToCSV, contains: "Row 2 has 1 fields")
    }

    private func expectIssue(_ input: String, direction: CSVJSON.Direction, contains text: String) {
        do {
            _ = try CSVJSON.convert(input, direction: direction)
            Issue.record("Expected conversion to fail with \(text)")
        } catch {
            #expect(error.localizedDescription.contains(text), "\(error.localizedDescription)")
        }
    }
}
