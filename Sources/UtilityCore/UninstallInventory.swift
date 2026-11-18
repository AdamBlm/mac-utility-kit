import AppKit
import Darwin
import Foundation

enum UninstallInventory {
    struct Environment: Sendable {
        let home: URL
        let applicationFolders: [URL]
        let owner: uid_t
        let ownBundle: URL
        let ownIdentifier: String?
        let registeredCopies: @Sendable (String) async -> [URL]
        let isRunning: @Sendable (String) async -> Bool

        static var system: Self {
            let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            return Self(
                home: home, applicationFolders: [URL(filePath: "/Applications"), home.appending(path: "Applications")],
                owner: getuid(), ownBundle: Bundle.main.bundleURL, ownIdentifier: Bundle.main.bundleIdentifier,
                registeredCopies: { identifier in
                    await MainActor.run { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier) }
                },
                isRunning: { identifier in
                    await MainActor.run {
                        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { !$0.isTerminated }
                    }
                }
            )
        }
    }

    struct BundleWitness: Equatable, Sendable {
        let url: URL
        let name: String
        let identifier: String
        let directory: DuplicateFileStamp
        let info: DuplicateFileStamp
        let executable: DuplicateFileStamp
    }

    static func application(_ input: URL, environment: Environment) throws -> BundleWitness {
        guard input.isFileURL else { throw ToolError.invalid("Choose a local application bundle.") }
        let url = input.standardizedFileURL
        guard url.pathExtension.lowercased() == "app",
              environment.applicationFolders.contains(where: { $0.standardizedFileURL.path == url.deletingLastPathComponent().path }),
              url.path == url.resolvingSymlinksInPath().path,
              url.path != environment.ownBundle.resolvingSymlinksInPath().path,
              let directory = try exactItem(url, kind: .app, owner: environment.owner) else {
            throw ToolError.invalid("Choose a removable app directly in Applications or your home Applications folder.")
        }
        let infoURL = url.appending(path: "Contents/Info.plist")
        guard let info = try readBundleInfo(url),
              let identifier = info["CFBundleIdentifier"] as? String, validIdentifier(identifier),
              !identifier.lowercased().hasPrefix("com.apple."),
              identifier.caseInsensitiveCompare("app.macutilitykit.preview") != .orderedSame,
              environment.ownIdentifier.map({ identifier.caseInsensitiveCompare($0) != .orderedSame }) ?? true,
              let executableName = info["CFBundleExecutable"] as? String,
              !executableName.isEmpty, !executableName.contains("/"), executableName != ".", executableName != "..",
              let infoStamp = try DuplicateFileIO.inspect(infoURL) else {
            throw ToolError.invalid("This application is protected or does not have verifiable bundle metadata.")
        }
        let executableURL = url.appending(path: "Contents/MacOS").appending(path: executableName)
        guard executableURL.resolvingSymlinksInPath().path == executableURL.path,
              FileManager.default.isExecutableFile(atPath: executableURL.path),
              let executable = try DuplicateFileIO.inspect(executableURL) else {
            throw ToolError.invalid("The application’s executable could not be verified.")
        }
        let name = (info["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        return BundleWitness(url: url, name: label, identifier: identifier, directory: directory, info: infoStamp,
                            executable: executable)
    }

    static func exactLeaves(_ id: String, home: URL) -> [(UninstallApp.Kind, URL)] {
        guard validIdentifier(id) else { return [] }
        let library = home.appending(path: "Library")
        let locations: [(UninstallApp.Kind, String, String)] = [
            (.cache, "Caches", id), (.preferences, "Preferences", id + ".plist"),
            (.support, "Application Support", id), (.container, "Containers", id),
            (.savedState, "Saved Application State", id + ".savedState"), (.scripts, "Application Scripts", id)
        ]
        return locations.map { kind, folder, name in (kind, library.appending(path: folder).appending(path: name)) }
    }

    static func hasOtherOwner(_ app: BundleWitness, environment: Environment) async -> Bool {
        let registered = await environment.registeredCopies(app.identifier)
        for candidate in registered where candidate.isFileURL && candidate.pathExtension.lowercased() == "app" {
            let url = candidate.resolvingSymlinksInPath().standardizedFileURL
            if url.path != app.url.path, FileManager.default.fileExists(atPath: url.path) { return true }
        }

        for folder in environment.applicationFolders {
            let local: [URL]
            do {
                local = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            } catch let error as NSError {
                // A missing Applications directory is normal, but unreadable ownership
                // evidence is not sufficient to offer shared-looking leftovers.
                if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { continue }
                return true
            }
            for candidate in local where candidate.pathExtension.lowercased() == "app" {
                let url = candidate.resolvingSymlinksInPath().standardizedFileURL
                if url.path != app.url.path,
                   let info = try? readBundleInfo(url),
                   let identifier = info["CFBundleIdentifier"] as? String,
                   identifier.caseInsensitiveCompare(app.identifier) == .orderedSame {
                    return true
                }
            }
        }
        return false
    }

    static func exactItem(
        _ url: URL, kind: UninstallApp.Kind, owner: uid_t
    ) throws -> DuplicateFileStamp? {
        var current = stat()
        if lstat(url.path, &current) != 0 {
            let error = errno
            if error == ENOENT { return nil }
            throw ToolError.invalid(String(cString: strerror(error)))
        }
        let type = current.st_mode & S_IFMT
        let flags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_RESTRICTED | SF_NOUNLINK)
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
              type == (kind.isDirectory ? S_IFDIR : S_IFREG), current.st_uid == owner,
              current.st_flags & flags == 0 else {
            throw ToolError.invalid("This path is linked, protected, or owned by another account.")
        }
        return DuplicateFileStamp(current)
    }

    private static func readBundleInfo(_ url: URL) throws -> [String: Any]? {
        let file = url.appending(path: "Contents/Info.plist")
        guard file.path == file.resolvingSymlinksInPath().path,
              let stamp = try DuplicateFileIO.inspect(file), (1...1024 * 1024).contains(stamp.bytes) else { return nil }
        let data = try Data(contentsOf: file)
        guard let fields = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              fields["CFBundlePackageType"] as? String == "APPL" else { return nil }
        return fields
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/) != nil
    }
}
