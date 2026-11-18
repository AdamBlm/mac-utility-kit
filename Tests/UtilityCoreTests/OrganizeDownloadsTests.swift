import Darwin
import Foundation
import Testing
@testable import UtilityCore

struct OrganizeDownloadsTests {
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

    @Test func groupsBrowserMetadataAndCopiesWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "Source")
        let target = root.appending(path: "Target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2XxkAAAAASUVORK5CYII="))
        let known = source.appending(path: "Known.png")
        let unknown = source.appending(path: "Unknown.png")
        try bytes.write(to: known)
        try bytes.write(to: unknown)
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["https://cdn.example.test/photo.png", "https://Page.Example.test/gallery"], format: .binary, options: 0
        )
        let wrote = metadata.withUnsafeBytes {
            setxattr(known.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        #expect(wrote == 0)
        let originFolder = target.appending(path: "page.example.test")
        try FileManager.default.createDirectory(at: originFolder, withIntermediateDirectories: false)
        let prior = originFolder.appending(path: "Known.png")
        try Data("existing".utf8).write(to: prior)

        let destination = try OrganizeDownloads.inspectDestination(target)
        let items = try OrganizeDownloads.scan(source)
        #expect(items.count == 2)
        #expect(items.first?.origin == "page.example.test")
        #expect(items.last?.origin == nil)
        let outcome = try OrganizeDownloads.export(items, to: destination, action: .copy)
        #expect(outcome.failures.isEmpty && outcome.completed.count == 2, "\(outcome.failures)")
        #expect(try Data(contentsOf: prior) == Data("existing".utf8))
        #expect(try Data(contentsOf: originFolder.appending(path: "Known 2.png")) == bytes)
        #expect(FileManager.default.fileExists(atPath: unknown.path))

        try Data("changed".utf8).write(to: known)
        let moved = try OrganizeDownloads.export(items, to: destination, action: .move)
        #expect(moved.failures.count == 1 && moved.completed.count == 1)
        #expect(FileManager.default.fileExists(atPath: known.path))
        #expect(!FileManager.default.fileExists(atPath: unknown.path))
    }
}
