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
        let workspaceStatus = "registered"
        let automation: Automation
        let prerequisites: [Prerequisite]
    }

    private struct Automation: Encodable {
        let cliCommand: String?
        let mcp: MCPAccess?
    }

    private struct MCPAccess: Encodable {
        let capability: String
        let requiresExplicitOptIn = true
    }

    private struct Prerequisite: Encodable {
        enum ID: String, Encodable {
            case singlePDF
            case libreOffice
            case existingDestinationDirectory
            case explicitAllow
            case externalExecutable
        }

        enum Surface: String, Encodable {
            case app, cli, mcp
        }

        let id: ID
        let surface: Surface
        var executable: String? = nil
        var operations: [Operation]? = nil

        enum Operation: String, Encodable {
            case export, inspect, download
        }
    }

    func run() throws {
        var cliCommands: [Tool: String] = [:]
        var fileCommands: Set<Tool> = []
        for case let command as any CatalogCommandBinding.Type in MacUtilityCLI.configuration.subcommands {
            cliCommands[command.catalogTool] = command.configuration.commandName
            if command is any FileJobCatalogCommand.Type { fileCommands.insert(command.catalogTool) }
        }
        let mcpCapabilities = Dictionary(uniqueKeysWithValues: StartMCP.Capability.allCases.map {
            ($0.catalogTool, MCPAccess(capability: $0.rawValue))
        })
        let entries = Tool.allCases.map { tool in
            var prerequisites: [Prerequisite] = []
            if tool.requiresSinglePDF { prerequisites.append(.init(id: .singlePDF, surface: .app)) }
            if tool.officePDFKind != nil { prerequisites.append(.init(id: .libreOffice, surface: .app)) }
            if tool == .addPassword || tool == .removePassword {
                prerequisites.append(.init(id: .externalExecutable, surface: .app,
                                           executable: PDFProtection.executableName, operations: [.export]))
            }
            if tool == .downloadVideo {
                prerequisites.append(.init(id: .externalExecutable, surface: .app,
                                           executable: VideoDownload.executableName, operations: [.inspect, .download]))
            }
            if fileCommands.contains(tool) { prerequisites.append(.init(id: .existingDestinationDirectory, surface: .cli)) }
            if mcpCapabilities[tool] != nil { prerequisites.append(.init(id: .explicitAllow, surface: .mcp)) }
            return Entry(id: tool.id, title: tool.title, category: tool.category, inputTypes: tool.inputTypes.map(\.identifier),
                         automation: Automation(cliCommand: cliCommands[tool], mcp: mcpCapabilities[tool]),
                         prerequisites: prerequisites)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(entries), as: UTF8.self))
    }
}
