import Foundation
import Testing
import UtilityCore

@MainActor
struct DraftRetentionTests {
    @MainActor
    private final class Fixture {
        let domain = "DraftRetentionTests.\(UUID())"
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let defaults: UserDefaults
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var canDelete = true

        init() throws {
            defaults = try #require(UserDefaults(suiteName: domain))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }

        var file: URL { folder.appending(path: "drafts.json") }

        func store(using preferences: UserDefaults? = nil) -> DraftRetention {
            DraftRetention(defaults: preferences ?? defaults, file: file, removeFile: { [unowned self] url in
                guard canDelete else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            }, now: { [unowned self] in now }, retryDelay: .milliseconds(15))
        }

        func clean() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func failedDisableDoesNotRestoreDraftsAfterRestartOrReenable() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let original = fixture.store()
        original.setEnabled(true)
        original.record("private text", for: .wordCounter)
        original.persist()
        try #require(FileManager.default.fileExists(atPath: fixture.file.path))

        fixture.canDelete = false
        original.setEnabled(false)
        #expect(original.issue != nil)

        let reopenedPreferences = try #require(UserDefaults(suiteName: fixture.domain))
        let relaunched = fixture.store(using: reopenedPreferences)
        relaunched.start()
        #expect(relaunched.issue != nil)
        relaunched.setEnabled(true)
        #expect(relaunched.retained(for: .wordCounter) == nil)
        relaunched.record("new text", for: .wordCounter)
        #expect(relaunched.retained(for: .wordCounter) == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))

        fixture.canDelete = true
        relaunched.persist()
        #expect(relaunched.issue == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        relaunched.record("fresh text", for: .wordCounter)
        relaunched.persist()
        #expect(fixture.store().retained(for: .wordCounter) == "fresh text")
    }

    @Test func expiredDraftStaysUnavailableWhileDeletionIsRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = fixture.store()
        store.setEnabled(true)
        store.record("old text", for: .caseConverter)
        store.persist()

        fixture.canDelete = false
        fixture.now += 7 * 24 * 60 * 60
        store.persist()
        #expect(store.retained(for: .caseConverter) == nil)
        #expect(store.issue != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))

        fixture.canDelete = true
        for _ in 0..<100 where store.issue != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.issue == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }
}
