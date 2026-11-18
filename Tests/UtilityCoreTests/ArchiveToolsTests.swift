import Foundation
import Testing
@testable import UtilityCore

struct ArchiveToolsTests {
    @Test func zipRoundTripSupportsSelectionAndKeepsConflicts() async throws {
        let stage = try staging()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = stage.appending(path: "Source")
        let output = stage.appending(path: "Destination")
        let folder = source.appending(path: "Résumé")
        try folder.ensureDirectory()
        try output.ensureDirectory()
        try Data("hello".utf8).write(to: folder.appending(path: "notes.txt"))
        try Data("world".utf8).write(to: folder.appending(path: "other.txt"))
        try Data("outside selection".utf8).write(to: source.appending(path: "root.txt"))
        let zip = stage.appending(path: "Example.zip")
        try await ArchiveTools.create([source], to: zip)
        let entries = try await ArchiveTools.list(zip)
        #expect(entries.map(\.path) == ["Source", "Source/Résumé", "Source/Résumé/notes.txt", "Source/Résumé/other.txt", "Source/root.txt"])
        let selected = try #require(entries.first { $0.path == "Source/Résumé" })
        try output.appending(path: "Source").ensureDirectory()
        let original = output.appending(path: "Source/original.txt")
        try Data("keep".utf8).write(to: original)

        let skipped = try await ArchiveTools.extract(zip, to: output, selected: [selected.id], conflicts: .skip)
        #expect(skipped.skipped == ["Source"])
        #expect(skipped.published.isEmpty)
        let renamed = try await ArchiveTools.extract(zip, to: output, selected: [selected.id], conflicts: .rename)
        #expect(renamed.renamed == ["Source": "Source (2)"])
        let name = try #require(renamed.published.first)
        #expect(try Data(contentsOf: name.appending(path: "Résumé/notes.txt")) == Data("hello".utf8))
        #expect(try Data(contentsOf: name.appending(path: "Résumé/other.txt")) == Data("world".utf8))
        #expect(!FileManager.default.fileExists(atPath: name.appending(path: "root.txt").path))
        #expect(try Data(contentsOf: original) == Data("keep".utf8))
        await #expect(throws: ToolError.self) { try await ArchiveTools.create([source], to: zip) }
    }

    @Test func aesPasswordRoundTripAndWrongPasswordLeavesDestinationIntact() async throws {
        let stage = try staging()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = stage.appending(path: "secret")
        let output = stage.appending(path: "Destination")
        let zip = stage.appending(path: "Encrypted.zip")
        try output.ensureDirectory()
        try Data("secret document".utf8).write(to: source)
        try await ArchiveTools.create([source], to: zip, password: "secret-phrase")
        let listed = try await ArchiveTools.list(zip)
        #expect(listed.first?.isEncrypted == true)
        await #expect(throws: ToolError.self) {
            _ = try await ArchiveTools.extract(zip, to: output, password: "incorrect", conflicts: .skip)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        let result = try await ArchiveTools.extract(zip, to: output, password: "secret-phrase", conflicts: .skip)
        let extracted = try #require(result.published.first)
        #expect(try Data(contentsOf: extracted) == Data("secret document".utf8))
    }

    @Test func rejectsTraversalAndLinksBeforePublishingAnyEntries() async throws {
        let stage = try staging()
        defer { try? FileManager.default.removeItem(at: stage) }
        let output = stage.appending(path: "Destination")
        try output.ensureDirectory()
        for (index, unsafe) in [
            member("../escape.txt"), member("/absolute.txt"),
            member("redirect", type: "2", link: ".."), member("hardlink", type: "1", link: "safe.txt"),
            member("SAFE.txt")
        ].enumerated() {
            let tar = stage.appending(path: "Unsafe\(index).tar")
            try (member("safe.txt") + unsafe + Data(repeating: 0, count: 1024)).write(to: tar)
            await #expect(throws: ToolError.self) { _ = try await ArchiveTools.list(tar) }
            await #expect(throws: ToolError.self) { _ = try await ArchiveTools.extract(tar, to: output, conflicts: .skip) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
    }

    @Test func extractsSystemSevenZipAndCompressedTarFixtures() async throws {
        let stage = try staging()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = stage.appending(path: "original.txt")
        try Data("fixture data".utf8).write(to: source)
        let formats = [("--format=7zip", "7z"), ("-z", "tar.gz")]
        for (flag, suffix) in formats {
            let archive = stage.appending(path: "Fixture." + suffix)
            let target = stage.appending(path: "result-" + suffix)
            try target.ensureDirectory()
            try await ExternalTool.run(URL(filePath: "/usr/bin/tar"), name: "Fixture builder",
                                       arguments: ["-c", flag, "-f", archive.path, "-C", stage.path, source.lastPathComponent],
                                       directory: stage)
            #expect(try await ArchiveTools.list(archive).map(\.path) == ["original.txt"])
            let result = try await ArchiveTools.extract(archive, to: target, conflicts: .skip)
            let written = try #require(result.published.first)
            #expect(try Data(contentsOf: written) == Data("fixture data".utf8))
        }
    }

    @Test func extractsUpstreamRAR5FixtureWhenAvailable() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_UTILITY_RAR_TEST"] else { return }
        let stage = try staging()
        defer { try? FileManager.default.removeItem(at: stage) }
        let archive = URL(filePath: path)
        let entries = try await ArchiveTools.list(archive)
        #expect(entries.map(\.path) == ["test.bin"])
        let summary = try await ArchiveTools.extract(archive, to: stage, conflicts: .rename)
        let extracted = try #require(summary.published.first)
        #expect(try Data(contentsOf: extracted).count == 1200)
    }

    private func staging() throws -> URL {
        let stage = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try stage.ensureDirectory()
        return stage
    }

    private func member(_ path: String, type: Character = "0", link: String = "") -> Data {
        var header = Array(repeating: UInt8(0), count: 512)
        func field(_ value: String, at index: Int) {
            header.replaceSubrange(index..<(index + value.utf8.count), with: value.utf8)
        }
        field(path, at: 0)
        field("0000644", at: 100)
        field("0000000", at: 108)
        field("0000000", at: 116)
        field("00000000000", at: 124)
        field("00000000000", at: 136)
        field("        ", at: 148)
        field(String(type), at: 156)
        field(link, at: 157)
        field("ustar", at: 257)
        field("00", at: 263)
        field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148)
        header[154] = 0
        return Data(header)
    }
}

private extension URL {
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
