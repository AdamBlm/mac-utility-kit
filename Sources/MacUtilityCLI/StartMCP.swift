import ArgumentParser
import MCP
import UtilityCore

struct StartMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Start an opt-in local MCP server over standard I/O.")

    @Option(parsing: .singleValue, help: "Enable a tool. Repeat to enable more than one.")
    var allow: [Capability] = []

    enum Capability: String, CaseIterable, ExpressibleByArgument, Sendable {
        case formatJSON = "format-json"
        case wordCount = "word-count"
        case cleanLink = "clean-link"

        var catalogTool: UtilityCore.Tool {
            switch self {
            case .formatJSON: .jsonFormatter
            case .wordCount: .wordCounter
            case .cleanLink: .cleanLinks
            }
        }

        var definition: MCP.Tool {
            MCP.Tool(name: rawValue, description: description, inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["text": .object(["type": .string("string")])]),
                "required": .array([.string("text")]),
                "additionalProperties": .bool(false)
            ]))
        }

        private var description: String {
            switch self {
            case .formatJSON: "Format JSON text and preserve exact number lexemes."
            case .wordCount: "Count words, characters, sentences, and paragraphs in text."
            case .cleanLink: "Clean a supplied link locally and return its destination without loading it."
            }
        }

        func call(_ text: String) async throws -> String {
            switch self {
            case .formatJSON:
                let result = try JSONFormatter.format(text, sortKeys: true)
                if !result.duplicateKeys.isEmpty {
                    throw ToolError.invalid("The supplied JSON has duplicate object keys.")
                }
                return result.text
            case .wordCount:
                let result = try await WordCounter.analyze(text)
                return "Words: \(result.words)\nCharacters: \(result.characters)\nSentences: \(result.sentences)\nParagraphs: \(result.paragraphs)"
            case .cleanLink:
                return try CleanLinks.clean(text).cleaned
            }
        }
    }

    func run() async throws {
        guard !allow.isEmpty else {
            throw ValidationError("Use --allow to enable at least one local tool.")
        }
        let enabled = Set(allow)
        let available = Capability.allCases.filter { enabled.contains($0) }.map(\.definition)
        let server = Server(name: "Mac Utility Kit", version: "0.0.1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: available) }
        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = Capability(rawValue: params.name), enabled.contains(tool) else {
                return .init(content: [.text(text: "This tool is not enabled.", annotations: nil, _meta: nil)], isError: true)
            }
            guard let arguments = params.arguments, arguments.count == 1, let text = arguments["text"]?.stringValue,
                  text.utf8.count <= 1_048_576 else {
                return .init(content: [.text(text: "Supply one text argument up to 1 MB.", annotations: nil, _meta: nil)], isError: true)
            }
            do {
                return .init(content: [.text(text: try await tool.call(text), annotations: nil, _meta: nil)], isError: false)
            } catch {
                return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
            }
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
        await server.stop()
    }
}
