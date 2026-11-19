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

    @Test(arguments: [false, true])
    func trashHandlesHardLinkChangeTimeWithoutAcceptingAnExternalEdit(editRemainingLink: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = root.appending(path: "Selected")
        let trash = root.appending(path: "Moved")
        let manager = FileManager.default
        for directory in [names, trash] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let first = names.appending(path: "first.txt")
        let second = names.appending(path: "second.txt")
        try Data("original".utf8).write(to: first)
        try manager.linkItem(at: first, to: second)
        let report = try await StorageExplorer.scan(names)
        let selected = report.items.filter(\.isHardLink)
        try #require(selected.count == 2)
        let result = await StorageExplorer.trash(Set(selected.map(\.id)), in: report) { source in
            try manager.moveItem(at: source, to: trash.appending(path: source.lastPathComponent))
            if editRemainingLink, source == selected[0].url {
                try Data("altered!".utf8).write(to: selected[1].url)
            }
        }
        if editRemainingLink {
            #expect(result.moved == [selected[0].url])
            #expect(result.issues.map(\.url) == [selected[1].url])
            #expect(manager.fileExists(atPath: selected[1].url.path))
        } else {
            #expect(result.issues.isEmpty)
            #expect(result.moved == selected.map(\.url))
        }
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

    @Test func customMinimumIsInclusiveAndDistinguishesNestedFilesWithTheSameName() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (folderName, byteCount) in [("A", 2_000_000), ("B", 2_000_000), ("C", 1_999_999)] {
            let folder = root.appending(path: folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data(repeating: 7, count: byteCount).write(to: folder.appending(path: "recording.bin"))
        }
        let report = try await StorageExplorer.scan(root)
        let minimum = try #require(StorageExplorer.minimumBytes(megabytes: " 2 "))
        let ids = try StorageExplorer.browserItems(in: report, directory: report.root.id,
                                                   minimumBytes: minimum, measurement: .apparent)
        #expect(ids.map { StorageExplorer.displayedPath(for: report.items[$0], under: report.root) }
                == ["A/recording.bin", "B/recording.bin"])
        let folder = try #require(report.items.first { $0.name == "A" })
        let nested = try StorageExplorer.browserItems(in: report, directory: folder.id,
                                                      minimumBytes: minimum, measurement: .apparent)
        #expect(nested.map { StorageExplorer.displayedPath(for: report.items[$0], under: folder) } == ["recording.bin"])
        for invalid in ["", "0", "-1", "1.5", "2 MB", "9223372036854775807"] {
            #expect(StorageExplorer.minimumBytes(megabytes: invalid) == nil)
        }
    }

    @Test func ordersScannedFilesBySizeNameOrModificationDate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        for (name, bytes, date) in [("File 10", 90, 200.0), ("File 2", 15, 300.0), ("File 1", 30, 300.0)] {
            let url = root.appending(path: name)
            try Data(repeating: 1, count: bytes).write(to: url)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: url.path)
        }
        let report = try await StorageExplorer.scan(root)
        func files(_ order: StorageExplorer.BrowserOrder) throws -> [String] {
            try StorageExplorer.browserItems(in: report, directory: report.root.id,
                minimumBytes: 20, measurement: .apparent, order: order).map { report.items[$0].name }
        }
        #expect(try files(.largest) == ["File 10", "File 1"])
        #expect(try files(.name) == ["File 1", "File 10"])
        #expect(try files(.newest) == ["File 1", "File 10"])
        #expect(try files(.oldest) == ["File 10", "File 1"])
        let all = try StorageExplorer.browserItems(in: report, directory: report.root.id,
            minimumBytes: nil, measurement: .apparent, order: .newest)
        #expect(all.map { report.items[$0].name } == ["File 1", "File 2", "File 10"])
    }

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
