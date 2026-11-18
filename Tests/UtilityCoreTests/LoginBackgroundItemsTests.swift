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

    @Test func distinguishesUnavailableInventoryFromEmptyRegistry() throws {
        #expect(throws: ToolError.self) {
            try LoginBackgroundItems.parse("Unrecognized response", userID: 501)
        }
        #expect(try LoginBackgroundItems.parse("Records for UID 501 : no items", userID: 501).isEmpty)
    }
}
