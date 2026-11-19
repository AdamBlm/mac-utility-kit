import CSystemArchive
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
        #expect(entries.first { $0.path.hasSuffix("/notes.txt") }?.uncompressedSize == 5)
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

    @Test(arguments: [false, true])
    func reviewedArchiveRejectsChangedContentsWithTheSameEntryIDs(inPlace: Bool) async throws {
        let stage = try staging()
        defer { try? FileManager.default.removeItem(at: stage) }
        let member = stage.appending(path: "photo.txt")
        let reviewedZIP = stage.appending(path: "Reviewed.zip")
        let replacementZIP = stage.appending(path: "Replacement.zip")
        let output = stage.appending(path: "Destination")
        try output.ensureDirectory()

        try Data("original".utf8).write(to: member)
        try await ArchiveTools.create([member], to: reviewedZIP)
        let listing = try await ArchiveTools.readContents(reviewedZIP)
        let selection = Set(listing.entries.map(\.id))

        try Data("modified".utf8).write(to: member)
        try await ArchiveTools.create([member], to: replacementZIP)
        let replacement = try Data(contentsOf: replacementZIP)
        if inPlace {
            let handle = try FileHandle(forWritingTo: reviewedZIP)
            defer { try? handle.close() }
            try handle.write(contentsOf: replacement)
            try handle.truncate(atOffset: UInt64(replacement.count))
            try handle.close()
        } else {
            try replacement.write(to: reviewedZIP, options: .atomic)
        }
        #expect(try await ArchiveTools.list(reviewedZIP).map(\.id) == listing.entries.map(\.id))
        let error = await #expect(throws: ToolError.self) {
            try await ArchiveTools.extract(reviewedZIP, listing: listing, to: output,
                                           selected: selection, conflicts: .skip)
        }
        #expect(error?.localizedDescription.contains("archive changed") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)

        let refreshed = try await ArchiveTools.readContents(reviewedZIP)
        let extracted = try await ArchiveTools.extract(reviewedZIP, listing: refreshed, to: output,
                                                       selected: selection, conflicts: .skip)
        let file = try #require(extracted.published.first)
        #expect(try Data(contentsOf: file) == Data("modified".utf8))
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

    @Test func cancellationInterruptsAnInProgressArchiveSkip() async throws {
        let stage = try staging()
        defer { try? FileManager.default.removeItem(at: stage) }
        let archive = stage.appending(path: "Fixture.tar")
        let size = 512 * 1024
        try (member("large.bin", size: size) + Data(repeating: 0, count: size + 1024)).write(to: archive)

        let task = Task.detached {
            try ArchiveTools.withReader(archive, password: nil) { reader in
                var entry: OpaquePointer?
                try ArchiveTools.check(archive_read_next_header(reader, &entry), reader)
                try #require(archive_entry_size(entry) == Int64(size))

                withUnsafeCurrentTask { $0?.cancel() }
                #expect(archive_read_data_skip(reader) < ARCHIVE_OK)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_RAR_TEST"] != nil))
    func extractsUpstreamRAR5FixtureWhenAvailable() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_RAR_TEST"])
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

    private func member(_ path: String, type: Character = "0", link: String = "", size: Int = 0) -> Data {
        var header = Array(repeating: UInt8(0), count: 512)
        func field(_ value: String, at index: Int) {
            header.replaceSubrange(index..<(index + value.utf8.count), with: value.utf8)
        }
        field(path, at: 0)
        field("0000644", at: 100)
        field("0000000", at: 108)
        field("0000000", at: 116)
        field(String(format: "%011o", size), at: 124)
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
