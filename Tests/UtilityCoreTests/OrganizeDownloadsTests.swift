import Darwin
import Foundation
import Testing
@testable import UtilityCore

struct OrganizeDownloadsTests {
    @Test func fileTypeUsesImageContentsInsteadOfFilenameSuffix() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let misleading = folder.appending(path: "Downloaded.jpg")
        let generic = folder.appending(path: "Generic.bin")
        let extensionless = folder.appending(path: "NoSuffix")
        let invalid = folder.appending(path: "Invalid.png")
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2XxkAAAAASUVORK5CYII="))
        try bytes.write(to: misleading)
        try bytes.write(to: generic)
        try bytes.write(to: extensionless)
        try Data("Not an image".utf8).write(to: invalid)
        let images = try OrganizeDownloads.scan(folder)
        #expect(images.map(\.relativePath) == ["Downloaded.jpg", "Generic.bin", "NoSuffix"])
        #expect(images.map(\.fileType) == ["PNG", "PNG", "PNG"])
        #expect(images.map(\.typeIdentifier) == ["public.png", "public.png", "public.png"])
        #expect(try Data(contentsOf: misleading) == bytes)
    }

    @Test func subfolderScanIsOptInAndLabelsDuplicateNamesWithoutFollowingLinks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let source = root.appending(path: "Downloads")
        let outside = root.appending(path: "Outside")
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2XxkAAAAASUVORK5CYII="))
        for directory in [source, source.appending(path: "Nested"), source.appending(path: ".Hidden"), outside] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: directory.appending(path: "Image.png"))
        }
        try manager.createSymbolicLink(at: source.appending(path: "External"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: source.appending(path: "Loop"), withDestinationURL: source)
        try manager.createSymbolicLink(at: source.appending(path: "Alias.png"), withDestinationURL: outside.appending(path: "Image.png"))

        #expect(try OrganizeDownloads.scan(source).map(\.relativePath) == ["Image.png"])
        let recursive = try OrganizeDownloads.scan(source, includesSubfolders: true)
        #expect(recursive.map(\.relativePath) == ["Image.png", "Nested/Image.png"])
        #expect(recursive.allSatisfy { $0.origin == nil && $0.fileType == "PNG" })
        let allFiles = Set(recursive.map(\.file))
        let first = try #require(recursive.first?.file)
        #expect(OrganizeDownloads.reviewedSelection(from: recursive, selected: allFiles, visible: [first]) == nil)
        #expect(OrganizeDownloads.reviewedSelection(from: recursive, selected: [first], visible: [first])?
            .map(\.file) == [first])
        #expect(OrganizeDownloads.reviewedSelection(from: recursive, selected: allFiles, visible: allFiles)?
            .map(\.file) == recursive.map(\.file))
    }

    @Test func rejectsReplacedDestinationAndSymlinkOriginWithoutMovingSource() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "Source")
        let target = root.appending(path: "Target")
        let other = root.appending(path: "Other")
        defer { try? manager.removeItem(at: root) }
        for folder in [source, target, other] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        let file = source.appending(path: "Image.png")
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2XxkAAAAASUVORK5CYII="))
        try bytes.write(to: file)
        let entries = try OrganizeDownloads.scan(source)
        let approved = try OrganizeDownloads.inspectDestination(target)
        let original = root.appending(path: "Original Target")
        try manager.moveItem(at: target, to: original)
        try manager.createSymbolicLink(at: target, withDestinationURL: other)
        #expect(throws: (any Error).self) { try OrganizeDownloads.export(entries, to: approved, action: .move) }
        try manager.removeItem(at: target)
        try manager.moveItem(at: original, to: target)
        try manager.createSymbolicLink(at: target.appending(path: "Unknown Source"), withDestinationURL: other)
        let rejected = try OrganizeDownloads.export(entries, to: approved, action: .move)
        #expect(rejected.completed.isEmpty && rejected.failures.count == 1)
        #expect(manager.fileExists(atPath: file.path))
        #expect(try manager.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test(arguments: [OrganizeDownloads.FileAction.copy, .move])
    func cancelledExportKeepsCompletedResultsAndLeavesRemainingSources(action: OrganizeDownloads.FileAction) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "Source")
        let target = root.appending(path: "Target")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2XxkAAAAASUVORK5CYII="))
        let first = source.appending(path: "First.png")
        let second = source.appending(path: "Second.png")
        try bytes.write(to: first)
        try bytes.write(to: second)
        let items = try OrganizeDownloads.scan(source)
        let destination = try OrganizeDownloads.inspectDestination(target)
        let worker = Task.detached {
            try OrganizeDownloads.export(items, to: destination, action: action) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let outcome = try await worker.value
        #expect(outcome.wasCancelled)
        #expect(outcome.completed.count == 1)
        let published = try #require(outcome.completed.first)
        #expect(URL(filePath: published).lastPathComponent == "First.png")
        #expect(try Data(contentsOf: URL(filePath: published)) == bytes)
        #expect(outcome.skipped.isEmpty && outcome.failures.isEmpty)
        #expect(try Data(contentsOf: second) == bytes)
        #expect(manager.fileExists(atPath: first.path) == (action == .copy))
        #expect(try manager.contentsOfDirectory(atPath: target.appending(path: "Unknown Source").path) == ["First.png"])
    }

    @Test func groupsBrowserMetadataAndCopiesWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "Source")
        let target = root.appending(path: "Target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2XxkAAAAASUVORK5CYII="))
        let known = source.appending(path: "Known.png")
        let ascii = source.appending(path: "Punycode.png")
        let unknown = source.appending(path: "Unknown.png")
        try bytes.write(to: known)
        try bytes.write(to: ascii)
        try bytes.write(to: unknown)
        for (file, host) in [(known, "Bücher.example"), (ascii, "xn--bcher-kva.example")] {
            let metadata = try PropertyListSerialization.data(
                fromPropertyList: ["https://cdn.example.test/photo.png", "https://\(host)/gallery"], format: .binary, options: 0
            )
            let wrote = metadata.withUnsafeBytes {
                setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            try #require(wrote == 0)
        }
        let originFolder = target.appending(path: "xn--bcher-kva.example")
        try FileManager.default.createDirectory(at: originFolder, withIntermediateDirectories: false)
        let prior = originFolder.appending(path: "Known.png")
        try Data("existing".utf8).write(to: prior)

        let destination = try OrganizeDownloads.inspectDestination(target)
        let items = try OrganizeDownloads.scan(source)
        #expect(items.count == 3)
        #expect(items.compactMap(\.origin) == ["xn--bcher-kva.example", "xn--bcher-kva.example"])
        #expect(items.last?.origin == nil)
        let outcome = try OrganizeDownloads.export(items, to: destination, action: .copy)
        #expect(outcome.failures.isEmpty && outcome.completed.count == 3, "\(outcome.failures)")
        #expect(try Data(contentsOf: prior) == Data("existing".utf8))
        #expect(try Data(contentsOf: originFolder.appending(path: "Known 2.png")) == bytes)
        #expect(try Data(contentsOf: originFolder.appending(path: "Punycode.png")) == bytes)
        #expect(FileManager.default.fileExists(atPath: unknown.path))

        try Data("changed".utf8).write(to: known)
        let moved = try OrganizeDownloads.export(items, to: destination, action: .move)
        #expect(moved.failures.count == 1 && moved.completed.count == 2)
        #expect(FileManager.default.fileExists(atPath: known.path))
        #expect(!FileManager.default.fileExists(atPath: unknown.path))
    }
}
