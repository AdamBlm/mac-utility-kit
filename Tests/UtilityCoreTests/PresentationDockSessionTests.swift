import Foundation
import Testing
@testable import UtilityCore

@MainActor
struct PresentationDockSessionTests {
    @Test func restoresAbsentDockDefaultAndPreservesExistingAutoHide() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = FakeDock(.missing)
        let session = try PresentationDockSession.start(in: folder, preferences: preferences)
        #expect(preferences.value == .autoHidden)
        #expect(try session.stop() == .restored)
        #expect(preferences.writes == [.autoHidden, .missing])
        #expect(preferences.reloads == 2)

        preferences.value = .autoHidden
        let existing = try PresentationDockSession.start(in: folder, preferences: preferences)
        #expect(try existing.stop() == .unchanged)
        #expect(preferences.writes == [.autoHidden, .missing])
    }

    @Test func leavesIndependentChangesAloneAtPollAndStop() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = FakeDock(.shown)
        let observed = try PresentationDockSession.start(in: folder, preferences: preferences)
        preferences.value = .shown
        #expect(try observed.relinquishIfChanged())
        preferences.value = .autoHidden
        #expect(try observed.stop() == .unchanged)
        #expect(preferences.value == .autoHidden)

        preferences.value = .shown
        let unobserved = try PresentationDockSession.start(in: folder, preferences: preferences)
        preferences.value = .missing
        #expect(try unobserved.stop() == .changedElsewhere)
        #expect(preferences.value == .missing)
        #expect(preferences.writes == [.autoHidden, .autoHidden])
    }

    @Test func recoversOnlyConfirmedWritesAfterAbandonedSession() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = FakeDock(.shown)
        do {
            _ = try PresentationDockSession.start(in: folder, preferences: preferences)
        }
        #expect(try PresentationDockSession.recover(in: folder, preferences: preferences) == .restored)
        #expect(preferences.value == .shown)

        let journal = folder.appending(path: "dock-recovery.json")
        try Data(#"{"phase":"preparing","original":"shown"}"#.utf8).write(to: journal)
        preferences.value = .autoHidden
        #expect(try PresentationDockSession.recover(in: folder, preferences: preferences) == .uncertain)
        #expect(preferences.value == .autoHidden)
        #expect(preferences.writes == [.autoHidden, .shown])
    }

    @Test func retainsRecoveryJournalWhenDockReloadFails() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = FakeDock(.shown)
        let session = try PresentationDockSession.start(in: folder, preferences: preferences)
        preferences.failReload = true
        #expect(throws: ToolError.self) { try session.stop() }
        #expect(preferences.value == .shown)
        preferences.failReload = false
        #expect(try PresentationDockSession.recover(in: folder, preferences: preferences) == .restored)
        #expect(preferences.writes == [.autoHidden, .shown])
    }

    @Test func recoveryCannotModifySettingsWhileAProcessOwnsTheSession() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = FakeDock(.missing)
        let live = try PresentationDockSession.start(in: folder, preferences: preferences)
        #expect(throws: ToolError.self) {
            try PresentationDockSession.recover(in: folder, preferences: preferences)
        }
        #expect(preferences.value == .autoHidden)
        #expect(try live.stop() == .restored)
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private final class FakeDock: PresentationDockPreferences {
        var value: PresentationDockValue
        var writes: [PresentationDockValue] = []
        var reloads = 0
        var failReload = false

        init(_ value: PresentationDockValue) { self.value = value }
        func read() throws -> PresentationDockValue { value }
        func write(_ value: PresentationDockValue) throws { self.value = value; writes.append(value) }
        func reload() throws {
            if failReload { throw ToolError.invalid("Fixture reload failed.") }
            reloads += 1
        }
    }
}
