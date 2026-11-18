import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DownloadImage: Identifiable, Sendable {
    public var id: URL { file }
    public let file: URL
    public let origin: String?
    public let fileType: String
    fileprivate let stamp: DuplicateFileStamp
}

public struct DownloadsResult: Sendable {
    public var completed: [String] = []
    public var skipped: [String] = []
    public var failures: [String] = []
}

public struct DownloadDestination: Sendable {
    public let directory: URL
    fileprivate let identity: DuplicateFileIdentity
}

public enum OrganizeDownloads {
    public enum FileAction: String, CaseIterable, Identifiable, Sendable {
        case copy = "Copy"
        case move = "Move"
        public var id: Self { self }
    }

    public static func scan(_ directory: URL) throws -> [DownloadImage] {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard root.isFileURL, try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ToolError.invalid("Choose a local source folder.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles])
        guard files.count <= 20_000 else { throw ToolError.invalid("Choose a folder containing up to 20,000 items.") }
        return try files.compactMap { file -> DownloadImage? in
            try Task.checkCancellation()
            guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
                  let stamp = try? DuplicateFileIO.inspect(file) else { return nil }
            let canonical = file.resolvingSymlinksInPath().standardizedFileURL
            guard (try? DuplicateFileIO.inspect(canonical)) == stamp,
                  let image = CGImageSourceCreateWithURL(canonical as CFURL, nil),
                  CGImageSourceGetCount(image) > 0 else { return nil }
            return DownloadImage(file: canonical, origin: sourceOrigin(canonical), fileType: file.pathExtension.uppercased(), stamp: stamp)
        }.sorted { $0.file.lastPathComponent.localizedStandardCompare($1.file.lastPathComponent) == .orderedAscending }
    }

    public static func inspectDestination(_ url: URL) throws -> DownloadDestination {
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let directory = try openDirectory(root)
        defer { close(directory) }
        return DownloadDestination(directory: root, identity: try folderIdentity(directory))
    }

    public static func export(_ entries: [DownloadImage], to destination: DownloadDestination, action: FileAction) throws -> DownloadsResult {
        let fd = try openDirectory(destination.directory)
        defer { close(fd) }
        guard try folderIdentity(fd) == destination.identity else {
            throw ToolError.invalid("The selected destination changed. Choose the folder again.")
        }
        var outcome = DownloadsResult()
        var used: Set<URL> = []
        for entry in entries {
            try Task.checkCancellation()
            guard used.insert(entry.file).inserted else { outcome.skipped.append(entry.file.lastPathComponent); continue }
            do {
                let folderName = entry.origin ?? "Unknown Source"
                let folder = destination.directory.appending(path: folderName, directoryHint: .isDirectory)
                let origin = try ArchiveStage.openDirectory(folderName, in: fd)
                defer { close(origin) }
                let path = try withSource(entry) { sourceFolder, sourceName, source in
                    guard try folderIdentity(sourceFolder) != folderIdentity(origin) else { return nil as URL? }
                    if action == .move {
                        return try publish(for: entry.file, folder: folder) { name in
                            try checkOpenedSource(entry, parent: sourceFolder, name: sourceName, opened: source)
                            let code = renameatx_np(sourceFolder, sourceName, origin, name, UInt32(RENAME_EXCL))
                            if code != 0, errno == EXDEV {
                                throw ToolError.invalid("Use Copy to export to a different volume.")
                            }
                            return code
                        }
                    }
                    return try copy(source, named: entry.file, to: origin, folder: folder)
                }
                if let path { outcome.completed.append(path.path) }
                else { outcome.skipped.append(entry.file.lastPathComponent + " · already in this origin folder") }
            } catch {
                outcome.failures.append(entry.file.lastPathComponent + " · " + error.localizedDescription)
            }
        }
        return outcome
    }

    static func copyForPhotos(_ entry: DownloadImage, into folder: URL) throws -> URL {
        let fd = try openDirectory(folder)
        defer { close(fd) }
        return try withSource(entry) { _, _, source in try copy(source, named: entry.file, to: fd, folder: folder) }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw ToolError.invalid("Choose a local folder.") }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix(errno) }
        return descriptor
    }

    private static func folderIdentity(_ fd: Int32) throws -> DuplicateFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posix(errno) }
        return DuplicateFileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func withSource<T>(_ entry: DownloadImage, perform: (Int32, String, Int32) throws -> T) throws -> T {
        try check(entry)
        let folder = try openDirectory(entry.file.deletingLastPathComponent())
        defer { close(folder) }
        let name = entry.file.lastPathComponent
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posix(errno) }
        defer { close(fd) }
        try checkOpenedSource(entry, parent: folder, name: name, opened: fd)
        return try perform(folder, name, fd)
    }

    private static func checkOpenedSource(_ entry: DownloadImage, parent: Int32, name: String, opened: Int32) throws {
        var openedInfo = stat()
        var namedInfo = stat()
        guard fstat(opened, &openedInfo) == 0, fstatat(parent, name, &namedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              openedInfo.st_mode & S_IFMT == S_IFREG, namedInfo.st_mode & S_IFMT == S_IFREG,
              DuplicateFileStamp(openedInfo) == entry.stamp, DuplicateFileStamp(namedInfo) == entry.stamp else {
            throw ToolError.invalid("This file has changed. Scan the source folder again.")
        }
    }

    private static func copy(_ source: Int32, named url: URL, to destination: Int32, folder: URL) throws -> URL {
        let temporary = ".muk-" + UUID().uuidString
        let fd = openat(destination, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix(errno) }
        defer {
            close(fd)
            _ = unlinkat(destination, temporary, 0)
        }
        guard fcopyfile(source, fd, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw posix(errno) }
        try Task.checkCancellation()
        return try publish(for: url, folder: folder) { name in
            renameatx_np(destination, temporary, destination, name, UInt32(RENAME_EXCL))
        }
    }

    private static func publish(for source: URL, folder: URL, rename: (String) throws -> Int32) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
        for count in 1...10_000 {
            let name = count == 1 ? source.lastPathComponent : "\(stem) \(count)\(suffix)"
            if try rename(name) == 0 { return folder.appending(path: name) }
            let error = errno
            if error != EEXIST { throw posix(error) }
        }
        throw ToolError.invalid("Could not find a unique name.")
    }

    private static func posix(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func check(_ entry: DownloadImage) throws {
        guard entry.file.resolvingSymlinksInPath().standardizedFileURL.path == entry.file.path,
              try DuplicateFileIO.inspect(entry.file) == entry.stamp else {
            throw ToolError.invalid("This file has changed. Scan the source folder again.")
        }
    }

    static func sourceOrigin(from metadata: Data) -> String? {
        guard let values = try? PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String] else { return nil }
        for value in values.reversed() {
            guard let address = URLComponents(string: value),
                  let scheme = address.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = address.percentEncodedHost?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                  !host.isEmpty, host.utf8.count <= 200,
                  host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { continue }
            return host
        }
        return nil
    }

    private static func sourceOrigin(_ url: URL) -> String? {
        let key = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard (1...65_536).contains(size) else { return nil }
        var bytes = Data(count: size)
        let read = bytes.withUnsafeMutableBytes { buffer in
            getxattr(url.path, key, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read == size else { return nil }
        return sourceOrigin(from: bytes)
    }

}
