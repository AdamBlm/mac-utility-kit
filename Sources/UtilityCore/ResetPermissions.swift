import Darwin
import Foundation

public enum ResetPermissionCategory: String, CaseIterable, Identifiable, Sendable {
    case camera = "Camera"
    case microphone = "Microphone"
    case screenRecording = "ScreenCapture"
    case accessibility = "Accessibility"
    case photos = "Photos"
    case speech = "SpeechRecognition"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .speech: "Speech Recognition"
        default: rawValue
        }
    }
}

public struct PermissionResetTarget: Equatable, Sendable {
    public let app: URL
    public let name: String
    public let bundleIdentifier: String
    fileprivate let bundleStamp: DuplicateFileStamp
    fileprivate let metadataStamp: DuplicateFileStamp
}

public enum ResetPermissions {
    public static func inspect(_ input: URL) throws -> PermissionResetTarget {
        let app = input.resolvingSymlinksInPath().standardizedFileURL
        guard app.isFileURL, app.pathExtension.lowercased() == "app",
              let bundleStamp = directoryStamp(app) else {
            throw ToolError.invalid("Choose a macOS application bundle.")
        }
        let infoURL = app.appending(path: "Contents/Info.plist")
        guard let metadataStamp = try? DuplicateFileIO.inspect(infoURL), metadataStamp.bytes <= 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "APPL", let identifier = info["CFBundleIdentifier"] as? String,
              validIdentifier(identifier) else {
            throw ToolError.invalid("The app has no valid bundle identifier.")
        }
        let label = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        guard directoryStamp(app) == bundleStamp, try DuplicateFileIO.inspect(infoURL) == metadataStamp else {
            throw ToolError.invalid("The selected app changed. Choose it again before resetting permissions.")
        }
        return PermissionResetTarget(app: app, name: label, bundleIdentifier: identifier,
                                     bundleStamp: bundleStamp, metadataStamp: metadataStamp)
    }

    public static func reset(_ target: PermissionResetTarget, category: ResetPermissionCategory) async throws {
        try await reset(target, category: category) { arguments in
            let folder = FileManager.default.temporaryDirectory.appending(path: ".muk-permissions-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            try await ExternalTool.run(URL(filePath: "/usr/bin/tccutil"), name: "macOS permission reset",
                                       arguments: arguments, directory: folder)
        }
    }

    static func reset(
        _ target: PermissionResetTarget, category: ResetPermissionCategory,
        invoke: @Sendable ([String]) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let current = try inspect(target.app)
        guard current == target else {
            throw ToolError.invalid("The selected app changed. Choose it again before resetting permissions.")
        }
        try Task.checkCancellation()
        try await invoke(["reset", category.rawValue, current.bundleIdentifier])
    }

    private static func directoryStamp(_ url: URL) -> DuplicateFileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return DuplicateFileStamp(info)
    }

    private static func validIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard identifier.utf8.count <= 255, parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, let first = part.utf8.first, first != 45 else { return false }
            return part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}
