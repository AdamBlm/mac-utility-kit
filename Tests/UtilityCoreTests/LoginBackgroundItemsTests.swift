import Foundation
import Testing
@testable import UtilityCore

struct LoginBackgroundItemsTests {
    @Test func parsesKnownFieldsAndPreservesUnknownAndSeparateRecords() throws {
        let inventory = """
         ========================
         Records for UID -2 : placeholder
         ========================
         #1:
          Name: Shared Daemon
          Type: legacy daemon (0x10010)
          Developer Name: (null)
          Disposition: [enabled, not allowed, notified] (0x9)
          URL: file:///Library/LaunchDaemons/Shared%20Daemon.plist
         #2:
          Name: Ignored Developer
          Type: developer (0x20)
         ========================
         Records for UID 501 : placeholder
         ========================
         #1:
          Name: Example Helper
          Type: login item (0x4)
          Identifier: com.example.helper
          Developer Name: Example: Publisher
          URL: Contents/Library/LoginItems/Example.app
          Executable Path: (null)
          Disposition: [disabled, allowed, notified] (0xa)
          Assoc. Bundle IDs: 1
             #1: com.example.unrelated
         #2:
          Name: Example Helper
          Bundle Identifier: com.example.other
          Type: future classification (0xfe)
          Disposition: [unexpected] (0x56)
         ========================
         Records for UID 502 : placeholder
         ========================
         #1:
          Name: Separate Account
          Type: app (0x2)
        """
        let entries = try LoginBackgroundItems.parse(inventory, userID: 501)
        #expect(entries.count == 3)
        #expect(Set(entries.map(\.id)).count == 3)
        let daemon = try #require(entries.first { $0.kind == .daemon })
        #expect(daemon.systemWide)
        #expect(daemon.status == .disallowed)
        #expect(daemon.publisher == nil)
        #expect(daemon.location?.path == "/Library/LaunchDaemons/Shared Daemon.plist")
        let login = try #require(entries.first { $0.kind == .loginItem })
        #expect(login.publisher == "Example: Publisher")
        #expect(login.status == .disabled)
        #expect(login.identifier == "com.example.helper")
        #expect(login.location == nil)
        #expect(entries.first { $0.kind == .unknown }?.status == .unknown)
    }

    @Test func revealsTheExecutableWhenItsRegistrationSourceIsMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Registration.plist")
        let executable = folder.appending(path: "Background Helper")
        try Data().write(to: executable)
        let inventory = """
        Records for UID 501 : placeholder
        #1:
         Name: Example Helper
         Type: agent (0x8)
         URL: \(source.absoluteString)
         Executable Path: \(executable.path)
        """
        let entry = try #require(LoginBackgroundItems.parse(inventory, userID: 501).first)
        #expect(entry.location?.path == source.path)
        #expect(entry.revealLocation?.path == executable.path)

        try Data().write(to: source)
        #expect(entry.revealLocation?.path == source.path)

        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: executable)
        #expect(entry.revealLocation == nil)
    }

    @Test func resolvesOnlyBundledHelpersWithAUniqueLocalParentInTheirScope() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let parent = folder.appending(path: "Example App.app")
        let contents = parent.appending(path: "Contents/Library/LoginItems")
        try manager.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let helper = contents.appending(path: "Example Helper.app")
        try manager.createDirectory(at: helper, withIntermediateDirectories: false)
        let outside = folder.appending(path: "Outside.app")
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: contents.appending(path: "Escaping.app"), withDestinationURL: outside)

        let app = """
         Name: Parent App
         Identifier: com.example.parent
         Type: app (0x2)
         URL: \(parent.absoluteString)
        """
        func child(_ number: Int, _ name: String, _ source: String, parentID: String = "com.example.parent") -> String {
            """
            #\(number):
             Name: \(name)
             Type: login item (0x4)
             Parent Identifier: \(parentID)
             URL: \(source)
            """
        }
        let relative = "Contents/Library/LoginItems/Example%20Helper.app"
        let records = [
            "Records for UID 501 : placeholder",
            child(1, "Safe", relative),
            child(2, "Escaping symlink", "Contents/Library/LoginItems/Escaping.app"),
            child(3, "Encoded traversal", "Contents/%2e%2e/Outside.app"),
            child(4, "Foreign scope", relative, parentID: "com.example.system"),
            child(5, "Safe directory URL", relative + "/"),
            "#6:\n" + app,
            "Records for UID -2 : placeholder",
            "#1:\n" + app.replacingOccurrences(of: "com.example.parent", with: "com.example.system")
        ]
        let entries = try LoginBackgroundItems.parse(records.joined(separator: "\n"), userID: 501)
        let safe = try #require(entries.first { $0.name == "Safe" })
        #expect(safe.sourcePath == relative)
        #expect(safe.revealLocation?.path == helper.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(entries.first { $0.name == "Safe directory URL" }?.revealLocation?.path == safe.revealLocation?.path)
        #expect(entries.filter { $0.kind == .loginItem && !$0.name.hasPrefix("Safe") }.allSatisfy { $0.revealLocation == nil })

        let ambiguous = try LoginBackgroundItems.parse(
            (Array(records.prefix(7)) + ["#7:\n" + app]).joined(separator: "\n"), userID: 501
        )
        #expect(ambiguous.first { $0.name == "Safe" }?.revealLocation == nil)
    }

    @Test func distinguishesUnavailableInventoryFromEmptyRegistry() throws {
        #expect(throws: ToolError.self) {
            try LoginBackgroundItems.parse("Unrecognized response", userID: 501)
        }
        #expect(try LoginBackgroundItems.parse("Records for UID 501 : no items", userID: 501).isEmpty)
    }
}
