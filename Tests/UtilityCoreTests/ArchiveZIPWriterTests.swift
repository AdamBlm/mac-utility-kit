import Foundation
import Testing
@testable import UtilityCore

struct ArchiveZIPWriterTests {
    @Test func directoryReplacementDuringTraversalAbandonsZIP() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "Original")
        let saved = root.appending(path: "Moved")
        let outside = root.appending(path: "Outside")
        let destination = root.appending(path: "Output")
        for folder in [source, outside, destination] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? files.removeItem(at: root) }
        let original = Data("selected".utf8)
        let unrelated = Data("unrelated".utf8)
        try original.write(to: source.appending(path: "Child.txt"))
        try unrelated.write(to: outside.appending(path: "Child.txt"))
        let existing = destination.appending(path: "Existing.txt")
        try unrelated.write(to: existing)
        let archive = destination.appending(path: "Export.zip")
        var replaced = false
        #expect(throws: ToolError.self) {
            try ArchiveTools.createZIP([source], to: archive) { path in
                #expect(path == "Original")
                try files.moveItem(at: source, to: saved)
                try files.createSymbolicLink(at: source, withDestinationURL: outside)
                replaced = true
            }
        }
        #expect(replaced)
        #expect(try files.contentsOfDirectory(atPath: destination.path) == ["Existing.txt"])
        #expect(try Data(contentsOf: existing) == unrelated)
        #expect(try Data(contentsOf: saved.appending(path: "Child.txt")) == original)
        #expect(try Data(contentsOf: outside.appending(path: "Child.txt")) == unrelated)
    }

    @Test func replacingAnEarlierRootBeforePublicationAbandonsZIP() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        let second = root.appending(path: "Second", directoryHint: .isDirectory)
        let destination = root.appending(path: "Output", directoryHint: .isDirectory)
        for folder in [second, destination] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? files.removeItem(at: root) }
        let first = root.appending(path: "First.txt")
        let child = second.appending(path: "Child.txt")
        let contents = Data("same bytes".utf8)
        for file in [first, child] { try contents.write(to: file) }

        #expect {
            try ArchiveTools.createZIP([first, second], to: destination.appending(path: "Export.zip")) { path in
                if path == "Second" { try contents.write(to: first, options: .atomic) }
            }
        } throws: { error in
            error.localizedDescription == "Source changed while creating the ZIP: First.txt"
        }
        #expect(try files.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try Data(contentsOf: first) == contents)
        #expect(try Data(contentsOf: child) == contents)
    }

    @Test func destinationMovedUnderSourceAbandonsZIP() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "Source")
        let child = source.appending(path: "Child")
        let destination = root.appending(path: "Output")
        let relocated = child.appending(path: "Relocated")
        for folder in [child, destination] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? files.removeItem(at: root) }
        let original = Data("preserve".utf8)
        try original.write(to: destination.appending(path: "Existing.txt"))
        #expect(throws: ToolError.self) {
            try ArchiveTools.createZIP([source], to: destination.appending(path: "Export.zip")) { path in
                if path == "Source" { try files.moveItem(at: destination, to: relocated) }
            }
        }
        #expect(try files.contentsOfDirectory(atPath: relocated.path) == ["Existing.txt"])
        #expect(try Data(contentsOf: relocated.appending(path: "Existing.txt")) == original)
    }
}
