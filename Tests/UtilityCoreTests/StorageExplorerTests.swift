import Darwin
import Foundation
import Testing
@testable import UtilityCore

struct StorageExplorerTests {
    @Test func nestedAllocatedUsageCountsHardLinksOnceAndSkipsSymlinkCycles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let regular = folder.appending(path: "regular.bin")
        let alias = root.appending(path: "alias.bin")
        let sparse = root.appending(path: "sparse.bin")
        let symlink = folder.appending(path: "loop")
        try Data(repeating: 7, count: 16 * 1024).write(to: regular)
        try FileManager.default.linkItem(at: regular, to: alias)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
        try Data().write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 32 * 1024 * 1024)
        try handle.close()

        let result = try await StorageExplorer.scan(root)
        let real = try #require(result.items.first { $0.name == "regular.bin" })
        let hardlink = try #require(result.items.first { $0.name == "alias.bin" })
        let hole = try #require(result.items.first { $0.name == "sparse.bin" })
        let folderItem = try #require(result.items.first { $0.name == "Nested" })
        let loop = try #require(result.items.first { $0.name == "loop" })
        #expect(result.items.count == 6)
        #expect(loop.kind == .link && !loop.canTrash && loop.children.isEmpty)
        #expect(folderItem.children.count == 2)
        #expect(real.isHardLink && hardlink.isHardLink)
        #expect(real.apparentBytes + hardlink.apparentBytes == 16 * 1024)
        #expect(result.root.apparentBytes == 32 * 1024 * 1024 + 16 * 1024)
        #expect(result.root.allocatedBytes == real.allocatedBytes + hardlink.allocatedBytes + hole.allocatedBytes)
        #expect(result.root.estimatedReclaimableBytes == hole.allocatedBytes)
        #expect(!result.root.canTrash)
    }

    @Test func trashRechecksFilesAndFolderDescendantsAndKeepsMixedOutcomes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let editedChild = folder.appending(path: "child")
        let editedFile = root.appending(path: "edited")
        let selectedOK = root.appending(path: "unchanged")
        for url in [editedChild, editedFile, selectedOK] { try Data("original".utf8).write(to: url) }

        let report = try await StorageExplorer.scan(root)
        let parent = try #require(report.items.first { $0.name == "Folder" })
        let child = try #require(report.items.first { $0.name == "child" })
        let file = try #require(report.items.first { $0.name == "edited" })
        let unchanged = try #require(report.items.first { $0.name == "unchanged" })
        let selected: Set<Int> = [parent.id, child.id, file.id, unchanged.id]
        let preview = StorageExplorer.trashPreview(selected, in: report)
        #expect(preview.items.map(\.name).sorted() == ["Folder", "edited", "unchanged"])
        try Data("changed file".utf8).write(to: editedFile)
        try Data("changed child".utf8).write(to: editedChild)

        var actedOn: [String] = []
        let result = await StorageExplorer.trash(selected, in: report) { url in
            actedOn.append(url.lastPathComponent)
        }
        #expect(actedOn == ["unchanged"])
        #expect(result.moved.map(\.lastPathComponent) == ["unchanged"])
        #expect(result.issues.map { $0.url.lastPathComponent }.sorted() == ["Folder", "edited"])
        #expect(FileManager.default.fileExists(atPath: editedChild.path))
    }

    @Test func unreadableDirectoryAppearsOnceAndBlocksAncestorTrash() async throws {
        guard getuid() != 0 else { return }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inaccessible = root.appending(path: "locked")
        try FileManager.default.createDirectory(at: inaccessible, withIntermediateDirectories: false)
        #expect(chmod(inaccessible.path, 0) == 0)
        defer { _ = chmod(inaccessible.path, 0o700) }
        let report = try await StorageExplorer.scan(root)
        #expect(report.items.count == 2)
        #expect(report.issues.map(\.url.lastPathComponent) == ["locked"])
        #expect(report.root.isPartial)
        #expect(report.items.last?.canTrash == false)
    }

    @Test func cancelledScanStopsBeforeReturningAReport() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StorageExplorer.scan(root)
        }
        await #expect(throws: CancellationError.self) { _ = try await scan.value }
    }

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
