import ArgumentParser
import Foundation
import UtilityCore

struct ConvertTable: CatalogCommandBinding {
    static let configuration = CommandConfiguration(
        commandName: "convert-table", abstract: "Convert CSV to JSON or Markdown, or JSON to CSV."
    )
    static let catalogTool = Tool.csvJSON

    @Argument(help: "Conversion direction.")
    var direction: Direction

    @Argument(help: "UTF-8 input path, or - for standard input.")
    var file = "-"

    @Option(name: .shortAndLong, help: "CSV delimiter. Auto is available for CSV input only.")
    var delimiter = Delimiter.comma

    @Flag(name: [.customShort("n"), .long], help: "Treat the first CSV row as data, or omit the output CSV header.")
    var noHeaders = false

    enum Direction: String, CaseIterable, ExpressibleByArgument {
        case csvToJSON = "csv-to-json"
        case jsonToCSV = "json-to-csv"
        case csvToMarkdown = "csv-to-markdown"

        var conversion: CSVJSON.Direction {
            switch self {
            case .csvToJSON: .csvToJSON
            case .jsonToCSV: .jsonToCSV
            case .csvToMarkdown: .csvToMarkdown
            }
        }
    }

    enum Delimiter: String, CaseIterable, ExpressibleByArgument {
        case comma, semicolon, tab, pipe, auto

        var separator: CSVJSON.Delimiter? {
            switch self {
            case .comma: .comma
            case .semicolon: .semicolon
            case .tab: .tab
            case .pipe: .pipe
            case .auto: nil
            }
        }
    }

    func validate() throws {
        if delimiter == .auto && direction == .jsonToCSV {
            throw ValidationError("Choose an explicit delimiter for CSV output.")
        }
    }

    func run() throws {
        let source = try readUTF8Text(file: file, limit: CSVJSON.maximumInputBytes,
                                      invalidInput: "Provide UTF-8 input up to 2 MiB.", preservesBOM: true)
        let separator = try delimiter.separator ?? detectedDelimiter(in: source)
        let output = try CSVJSON.convert(source, direction: direction.conversion, delimiter: separator,
                                         includesHeader: !noHeaders).output
        try FileHandle.standardOutput.write(contentsOf: Data(output.utf8))
    }

    private func detectedDelimiter(in source: String) throws -> CSVJSON.Delimiter {
        switch try CSVJSON.detectDelimiter(source) {
        case .detected(let separator): return separator
        case .ambiguous(let separators):
            let choices = separators.map { $0.rawValue.lowercased() }.joined(separator: ", ")
            throw ValidationError("Several delimiters fit (\(choices)). Choose one with --delimiter.")
        case .unavailable:
            throw ValidationError("Could not detect a delimiter. Choose one with --delimiter.")
        }
    }
}
