import Darwin
import Foundation
import Testing
@testable import UtilityCore

struct UninstallAppTests {
    @Test func onlyExactUnsharedOwnedPathsAppearAndNoFilesAreMovedByReview() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let cache = try fixture.create(.cache)
        let support = try fixture.create(.support)
        let preferences = try fixture.create(.preferences)
        let unsure = fixture.home.appending(path: "Library/Application Support/" + fixture.identifier + ".unrelated")
        try FileManager.default.createDirectory(at: unsure, withIntermediateDirectories: true)
        let group = fixture.home.appending(path: "Library/Group Containers/" + fixture.identifier)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let report = try await UninstallApp.review(fixture.app, environment: fixture.environment)
        #expect(report.bundleIdentifier == fixture.identifier)
        #expect(report.defaultSelection == [fixture.app])
        #expect(Set(report.items.map(\.url)) == [fixture.app, cache, support, preferences])
        let allTrashable = report.items.allSatisfy(\.canTrash)
        #expect(allTrashable)
        #expect(!report.associatedItemsShared)
        #expect(FileManager.default.fileExists(atPath: support.path))

        let copy = fixture.home.appending(path: "Applications/Second.app")
        try fixture.createApp(copy, identifier: fixture.identifier)
        let shared = try await UninstallApp.review(fixture.app, environment: fixture.environment)
        #expect(shared.associatedItemsShared)
        #expect(shared.items.map(\.url) == [fixture.app])
        var actedOn: [URL] = []
        let result = await UninstallApp.trash([cache], from: report, environment: fixture.environment) {
            actedOn.append($0)
        }
        #expect(actedOn.isEmpty)
        #expect(result.issues.map(\.url) == [cache])
    }

    @Test func rechecksDescendantsSymlinksAndOriginalBundleAndReportsMixedOutcomes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let cache = try fixture.create(.cache)
        let support = try fixture.create(.support)
        let preferences = try fixture.create(.preferences)
        let container = try fixture.create(.container)
        let scripts = try fixture.create(.scripts)
        let report = try await UninstallApp.review(fixture.app, environment: fixture.environment)
        try Data("Changed content".utf8).write(to: support.appending(path: "data.txt"))
        try FileManager.default.removeItem(at: preferences)
        try FileManager.default.createSymbolicLink(at: preferences, withDestinationURL: support.appending(path: "data.txt"))

        try FileManager.default.removeItem(at: scripts)

        var attempted: [URL] = []
        let result = await UninstallApp.trash([fixture.app, cache, support, preferences, container, scripts], from: report,
                                             environment: fixture.environment) { url in
            attempted.append(url)
            if url == container { throw ToolError.invalid("Permission denied") }
        }
        #expect(attempted == [cache, container, fixture.app])
        #expect(result.moved == [cache, fixture.app])
        #expect(Set(result.issues.map(\.url)) == [support, preferences, container, scripts])
        #expect(result.issues.first(where: { $0.url == scripts })?.reason == "This item no longer exists.")
        #expect(result.issues.first(where: { $0.url == container })?.reason == "Permission denied")
        #expect(FileManager.default.fileExists(atPath: support.appending(path: "data.txt").path))

        let running = await UninstallApp.trash([fixture.app], from: report, environment: fixture.makeEnvironment(running: true)) {
            Issue.record("The running app must never be moved: \($0.path)")
        }
        #expect(running.moved.isEmpty && running.issues.count == 1)
    }

    @Test func stoppingAfterFirstMoveKeepsPartialResultAndLeavesTheApp() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let cache = try fixture.create(.cache)
        let report = try await UninstallApp.review(fixture.app, environment: fixture.environment)
        let app = fixture.app
        let environment = fixture.environment
        let movedCache = fixture.home.appending(path: "Moved cache")
        let operation = Task.detached {
            await UninstallApp.trash([app, cache], from: report, environment: environment) { item in
                #expect(item == cache)
                try FileManager.default.moveItem(at: item, to: movedCache)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let result = await operation.value
        #expect(result.wasCancelled)
        #expect(result.moved == [cache])
        #expect(result.issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(try Data(contentsOf: movedCache.appending(path: "data.txt")) == Data("original".utf8))
    }

    @Test func refusesSystemIdentifierSelfAndAppsOutsideKnownApplicationRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let apple = fixture.home.appending(path: "Applications/System.app")
        let outside = fixture.home.appending(path: "Other.app")
        try fixture.createApp(apple, identifier: "com.apple.example")
        try fixture.createApp(outside, identifier: "org.example.overlap")
        for url in [apple, outside] {
            await #expect(throws: ToolError.self) { _ = try await UninstallApp.review(url, environment: fixture.environment) }
        }
        await #expect(throws: ToolError.self) {
            _ = try await UninstallApp.review(fixture.app, environment: fixture.makeEnvironment(own: fixture.app))
        }
    }

    private struct Fixture {
        let home: URL
        let app: URL
        let identifier = "org.example.test-uninstall"

        var environment: UninstallInventory.Environment { makeEnvironment() }

        init() throws {
            home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
            app = home.appending(path: "Applications/Sample.app", directoryHint: .isDirectory)
            try createApp(app, identifier: identifier)
        }

        func makeEnvironment(running: Bool = false, own: URL? = nil) -> UninstallInventory.Environment {
            .init(home: home, applicationFolders: [home.appending(path: "Applications")], owner: getuid(),
                  ownBundle: own ?? home.appending(path: "utility.app"), ownIdentifier: "org.example.helper",
                  registeredCopies: { _ in [] }, isRunning: { _ in running })
        }

        func createApp(_ url: URL, identifier: String) throws {
            let contents = url.appending(path: "Contents")
            let scripts = contents.appending(path: "MacOS")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            let metadata: [String: String] = [
                "CFBundlePackageType": "APPL", "CFBundleIdentifier": identifier, "CFBundleExecutable": "Sample"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            try data.write(to: contents.appending(path: "Info.plist"))
            let executable = scripts.appending(path: "Sample")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            #expect(chmod(executable.path, 0o700) == 0)
        }

        func create(_ kind: UninstallApp.Kind) throws -> URL {
            let url = try #require(UninstallInventory.exactLeaves(identifier, home: home).first { $0.0 == kind }?.1)
            if kind.isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("original".utf8).write(to: url.appending(path: "data.txt"))
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("original".utf8).write(to: url)
            }
            return url
        }

        func clean() { try? FileManager.default.removeItem(at: home) }
    }
}
