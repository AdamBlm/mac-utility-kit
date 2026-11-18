import ArgumentParser
import Foundation
import UtilityCore

struct Catalog: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the Mac Utility Kit tool catalog as JSON.")

    private struct Entry: Encodable {
        let id: String
        let title: String
        let category: String
    }

    func run() throws {
        let entries = Tool.allCases.map { Entry(id: $0.id, title: $0.title, category: $0.category) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(entries), as: UTF8.self))
    }
}
