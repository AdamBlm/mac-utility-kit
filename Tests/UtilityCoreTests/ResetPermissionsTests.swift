import Foundation
import Testing
@testable import UtilityCore

struct ResetPermissionsTests {
    @Test func scopesExactlyOneCategoryToTheSelectedBundle() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Example.app")
        try writeBundle(app, identifier: "com.example.fixture")
        let target = try ResetPermissions.inspect(app)
        #expect(target.bundleIdentifier == "com.example.fixture")
        try await ResetPermissions.reset(target, category: .screenRecording) { arguments in
            #expect(arguments == ["reset", "ScreenCapture", "com.example.fixture"])
        }
    }

    @Test func changedBundleAndMalformedIdentifiersCannotInvokeReset() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Example.app")
        try writeBundle(app, identifier: "com.example.fixture")
        let target = try ResetPermissions.inspect(app)
        try writeBundle(app, identifier: "com.example.replacement")
        await #expect(throws: ToolError.self) {
            try await ResetPermissions.reset(target, category: .microphone) { _ in
                Issue.record("A changed target reached the system reset callback.")
            }
        }
        try writeBundle(app, identifier: "--global")
        #expect(throws: ToolError.self) { try ResetPermissions.inspect(app) }
    }

    private func root() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func writeBundle(_ app: URL, identifier: String) throws {
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let values = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleName": "Example"]
        let plist = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"), options: .atomic)
    }
}
