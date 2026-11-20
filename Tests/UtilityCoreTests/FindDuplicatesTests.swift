import Darwin
import Foundation
import Testing
@testable import UtilityCore

@Suite(.serialized)
struct FindDuplicatesTests {
    @Test func keepSelectionMarksOnlyTheChosenGroupsOtherCopies() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try Self.write("a.txt", Data("first group".utf8), in: root)
        let b = try Self.write("b.txt", Data("first group".utf8), in: root)
        let c = try Self.write("c.txt", Data("first group".utf8), in: root)
        let d = try Self.write("d.txt", Data("second group".utf8), in: root)
        let e = try Self.write("e.txt", Data("second group".utf8), in: root)
        let report = try await FindDuplicates.scan([root], options: .init())
        let group = try #require(report.groups.first { $0.files.contains { $0.url == a } })
        let marked: Set<URL> = [b, d]
        let next = group.selection(keeping: b, from: marked)
        #expect(next == [a, c, d])
        #expect(group.selection(keeping: e, from: next) == next)
        #expect([a, b, c, d, e].allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func minimumSizeIsInclusiveAcrossFoldersAndLeavesDefaultUnchanged() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        for (folder, suffix) in [(root, "root"), (nested, "nested")] {
            _ = try Self.write("small-\(suffix)", Data(repeating: 1, count: 63), in: folder)
            _ = try Self.write("boundary-\(suffix)", Data(repeating: 2, count: 64), in: folder)
        }
        let all = try await FindDuplicates.scan([root], options: .init())
        #expect(all.groups.count == 2)
        var options = DuplicateScanOptions()
        options.minimumFileBytes = 64
        let filtered = try await FindDuplicates.scan([root], options: options)
        #expect(filtered.fileCount == 2)
        #expect(filtered.groups.map(\.fileSize) == [64])
        #expect(filtered.groups.first?.files.count == 2)
        options.minimumFileBytes = -1
        await #expect(throws: ToolError.self) { try await FindDuplicates.scan([root], options: options) }
    }

    @Test func filtersFullPathsButKeepsAllCopiesOfEachMatchingGroup() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appending(path: "Café archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let first = try Self.write("field notes.txt", Data("same first group".utf8), in: archive)
        let second = try Self.write("retained.txt", Data("same first group".utf8), in: root)
        _ = try Self.write("receipt.txt", Data("same second group".utf8), in: root)
        _ = try Self.write("receipt copy.txt", Data("same second group".utf8), in: root)

        let result = try await FindDuplicates.scan([root], options: .init())
        for query in ["  cafe archive ", "FIELD NOTES"] {
            let group = try #require(result.groups(matchingPath: query).first)
            #expect(result.groups(matchingPath: query).count == 1)
            #expect(Set(group.files.map(\.url)) == [first, second])
        }
        #expect(result.groups(matchingPath: "unmatched").isEmpty)
        #expect(result.groups(matchingPath: "  ").count == 2)
    }

    @Test
    func groupsExactLargeFilesAndIgnoresRepeatedIdentityAndSymlinks() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var bytes = Data(repeating: 23, count: 1_100_000)
        let a = try Self.write("a.dat", bytes, in: folder)
        let b = try Self.write("b.dat", bytes, in: folder)
        bytes[bytes.count - 1] = 24
        let different = try Self.write("different.dat", bytes, in: folder)
        let hard = folder.appending(path: "hard.dat")
        try FileManager.default.linkItem(at: a, to: hard)
        let symbolic = folder.appending(path: "symlink.dat")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: a)

        let report = try await FindDuplicates.scan([folder, folder], options: .init())
        #expect(report.fileCount == 3)
        #expect(report.issues.isEmpty)
        let group = try #require(report.groups.first)
        #expect(report.groups.count == 1)
        #expect(group.fileSize == 1_100_000)
        let files = Set(group.files.map(\.url))
        #expect(files.contains(b))
        #expect(files.contains(a) != files.contains(hard))
        #expect(!files.contains(different))
        #expect(!files.contains(symbolic))
        #expect(group.files.first { $0.url != b }?.estimatedReclaimableBytes == 0)
    }

    @Test
    func scansConfiguredHiddenAndNestedFilesAndReportsInvalidRoots() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let data = Data("equal".utf8)
        let visible = try Self.write("visible.txt", data, in: folder)
        let hidden = try Self.write(".hidden.txt", data, in: folder)
        let deep = try Self.write("deep.txt", data, in: nested)

        var options = DuplicateScanOptions()
        options.includesSubfolders = false
        let shallow = try await FindDuplicates.scan([folder], options: options)
        #expect(shallow.fileCount == 1)
        #expect(shallow.groups.isEmpty)
        options.includesSubfolders = true
        options.includesHiddenFiles = true
        let report = try await FindDuplicates.scan([folder, visible], options: options)
        #expect(report.fileCount == 3)
        #expect(Set(report.groups.flatMap(\.files).map(\.url)) == [visible, hidden, deep])
        #expect(report.issues.contains { $0.url == visible })
    }

    @Test(.enabled(if: geteuid() != 0))
    func reportsUnreadableFileAndStillGroupsReadableCopies() async throws {
        let root = try Self.folder()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        let data = Data("exact shared contents".utf8)
        let first = try Self.write("first.txt", data, in: root)
        let second = try Self.write("second.txt", data, in: root)
        let unreadable = try Self.write("unreadable.txt", data, in: root)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        #expect(access(unreadable.path, R_OK) != 0)

        let report = try await FindDuplicates.scan([root], options: .init())
        #expect(report.fileCount == 2)
        #expect(report.groups.count == 1)
        #expect(Set(report.groups.flatMap(\.files).map(\.url)) == [first, second])
        #expect(report.issues.count == 1)
        let issue = try #require(report.issues.first)
        #expect(issue.url.lastPathComponent == unreadable.lastPathComponent)
        #expect(try DuplicateFileIO.inspect(issue.url)?.identity == DuplicateFileIO.inspect(unreadable)?.identity)
        #expect(!issue.message.isEmpty)
    }

    @Test
    func retainsOneCopyAndRejectsChangedCandidateAndKeeper() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = Data("same content".utf8)
        let a = try Self.write("a.txt", data, in: folder)
        let b = try Self.write("b.txt", data, in: folder)
        let report = try await FindDuplicates.scan([folder], options: .init())

        await #expect(throws: ToolError.self) {
            try await FindDuplicates.trash([a, b], from: report) { _ in Issue.record("No file should be moved.") }
        }

        try data.write(to: a, options: .atomic)
        let changed = try await FindDuplicates.trash([a], from: report) { _ in Issue.record("A stale path should never be used.") }
        #expect(changed.moved.isEmpty)
        #expect(changed.failures.map(\.url) == [a])
        let noKeeper = try await FindDuplicates.trash([b], from: report) { _ in Issue.record("A stale keeper should never be accepted.") }
        #expect(noKeeper.moved.isEmpty)
        #expect(noKeeper.failures.first?.message.contains("kept copy") == true)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    @Test
    func reportsIndividualActionFailuresAndPreservesOtherGroups() async throws {
        let folder = try Self.folder()
        let mockTrash = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: mockTrash)
        }
        let keepA = try Self.write("keep-a.txt", Data("alpha".utf8), in: folder)
        let failed = try Self.write("fail-a.txt", Data("alpha".utf8), in: folder)
        let keepB = try Self.write("keep-b.txt", Data("bravo".utf8), in: folder)
        let selected = try Self.write("trash-b.txt", Data("bravo".utf8), in: folder)
        let report = try await FindDuplicates.scan([folder], options: .init())

        let result = try await FindDuplicates.trash([failed, selected], from: report) { url in
            if url == failed { throw ToolError.invalid("Trash unavailable for fixture.") }
            try FileManager.default.moveItem(at: url, to: mockTrash.appending(path: url.lastPathComponent))
        }
        #expect(result.moved == [selected])
        #expect(result.failures.map(\.url) == [failed])
        #expect(!result.wasCancelled)
        #expect(try Data(contentsOf: mockTrash.appending(path: selected.lastPathComponent)) == Data("bravo".utf8))
        #expect(FileManager.default.fileExists(atPath: keepA.path))
        #expect(FileManager.default.fileExists(atPath: keepB.path))
        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(report.removing(result.moved).groups.count == 1)
    }

    @Test
    func preventsOverlappingTrashActionsFromChoosingDifferentKeepers() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try Self.write("first.txt", Data("same".utf8), in: folder)
        let b = try Self.write("second.txt", Data("same".utf8), in: folder)
        let report = try await FindDuplicates.scan([folder], options: .init())
        let (events, entered) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let firstAction = Task.detached {
            defer { entered.finish() }
            return try await FindDuplicates.trash([a], from: report) { file in
                entered.yield()
                entered.finish()
                guard release.wait(timeout: .now() + .seconds(3)) == .success else {
                    throw ToolError.invalid("Fixture did not release the first Trash action.")
                }
                try FileManager.default.moveItem(at: file, to: folder.appending(path: "mock-trash.txt"))
            }
        }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        await #expect(throws: ToolError.self) {
            try await FindDuplicates.trash([b], from: report) { _ in
                Issue.record("Overlapping actions must not move a keeper.")
            }
        }
        release.signal()
        let result = try await firstAction.value
        #expect(result.moved == [a])
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    @Test
    func refusesAncestorReplacedBySymlinkToOutsideHardLink() async throws {
        let folder = try Self.folder()
        let outside = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        let inside = folder.appending(path: "subfolder")
        let parked = folder.appending(path: "parked")
        let manager = FileManager.default
        try manager.createDirectory(at: inside, withIntermediateDirectories: false)
        let data = Data("same contents".utf8)
        let file = try Self.write("copy.txt", data, in: inside)
        let keep = try Self.write("keep.txt", data, in: folder)
        let outsideLink = outside.appending(path: "copy.txt")
        try manager.linkItem(at: file, to: outsideLink)

        let report = try await FindDuplicates.scan([folder], options: .init())
        try #require(report.groups.first?.files.contains { $0.url == file } == true)
        try manager.moveItem(at: inside, to: parked)
        try manager.createSymbolicLink(at: inside, withDestinationURL: outside)
        let originalStamp = try #require(report.groups.first?.files.first(where: { $0.url == file })?.stamp)
        #expect(try DuplicateFileIO.inspect(file) == originalStamp)

        let result = try await FindDuplicates.trash([file], from: report) { _ in
            Issue.record("A redirected path must not reach the Trash action.")
        }
        #expect(result.moved.isEmpty)
        #expect(result.failures.map(\.url) == [file])
        #expect(try Data(contentsOf: outsideLink) == data)
        #expect(try Data(contentsOf: keep) == data)
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func write(_ name: String, _ bytes: Data, in folder: URL) throws -> URL {
        let file = folder.appending(path: name)
        try bytes.write(to: file)
        return file
    }
}
