import ArgumentParser
import Foundation
import UtilityCore

protocol CatalogCommandBinding: ParsableCommand {
    static var catalogTool: Tool { get }
}

struct Catalog: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the Mac Utility Kit tool catalog as JSON.")

    private struct Entry: Encodable {
        let id: String
        let title: String
        let category: String
        let inputTypes: [String]
        let automation: Automation
    }

    private struct Automation: Encodable {
        let cliCommand: String?
        let mcp: MCPAccess?
    }

    private struct MCPAccess: Encodable {
        let capability: String
        let requiresExplicitOptIn = true
    }

    func run() throws {
        var cliCommands: [Tool: String] = [:]
        for case let command as any CatalogCommandBinding.Type in MacUtilityCLI.configuration.subcommands {
            cliCommands[command.catalogTool] = command.configuration.commandName
        }
        let mcpCapabilities = Dictionary(uniqueKeysWithValues: StartMCP.Capability.allCases.map {
            ($0.catalogTool, MCPAccess(capability: $0.rawValue))
        })
        let entries = Tool.allCases.map { tool in
            Entry(id: tool.id, title: tool.title, category: tool.category, inputTypes: tool.inputTypes.map(\.identifier),
                  automation: Automation(cliCommand: cliCommands[tool], mcp: mcpCapabilities[tool]))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(entries), as: UTF8.self))
    }
}
