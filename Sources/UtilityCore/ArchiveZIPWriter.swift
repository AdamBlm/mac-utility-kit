import CSystemArchive
import Darwin
import Foundation

extension ArchiveTools {
    public static func create(_ inputs: [URL], to output: URL, password: String? = nil) async throws {
        try createZIP(inputs, to: output, password: password) { _ in }
    }

    static func createZIP(
        _ inputs: [URL], to output: URL, password: String? = nil,
        directoryListed: (String) throws -> Void
    ) throws {
        guard output.isFileURL, output.pathExtension.lowercased() == "zip", !inputs.isEmpty else {
            throw ToolError.invalid("Choose local files or folders and a ZIP destination.")
        }
        guard password?.utf8.contains(0) != true else {
            throw ToolError.invalid("The archive password contains an invalid character.")
        }
        let destination = output.deletingLastPathComponent()
        let destinationFD = try ArchivePublication.directory(destination)
        defer { close(destinationFD) }
        // A ZIP stored inside a selected directory would include its own staging
        // output during traversal.
        let destinationIdentity = try ArchivePublication.identity(".", in: destinationFD)
        let destinationLineage = try ArchivePublication.directoryLineage(destinationFD)
        let sources = try inputs.map { input in
            try Task.checkCancellation()
            guard input.isFileURL else { throw ToolError.invalid("Choose local files or folders.") }
            var details = stat()
            guard lstat(input.path, &details) == 0 else {
                throw ArchivePublication.error(errno, path: input.lastPathComponent)
            }
            guard !destinationLineage.contains(ArchivePublication.Identity(details)) else {
                throw ToolError.invalid("Choose a ZIP destination outside the folders being archived.")
            }
            return (input, details)
        }
        let stage = try ArchiveStage(in: destinationFD)
        defer { stage.remove() }
        let stagedName = "Output.zip"
        let fd = openat(stage.fd, stagedName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ArchivePublication.error(errno, path: output.lastPathComponent) }
        defer { close(fd) }
        try writeZIP(sources, to: fd, password: password, destination: destinationIdentity, directoryListed: directoryListed)
        try Task.checkCancellation()
        for (input, original) in sources {
            try Task.checkCancellation()
            var located = stat()
            guard lstat(input.path, &located) == 0, sameZIPSource(located, as: original) else {
                throw ToolError.invalid("Source changed while creating the ZIP: \(input.lastPathComponent)")
            }
        }
        guard (try? ArchivePublication.identity(destination.path, in: AT_FDCWD)) == destinationIdentity else {
            throw ToolError.invalid("The ZIP destination changed during creation.")
        }
        let result = ArchivePublication.move(stagedName, from: stage.fd,
                                             to: output.lastPathComponent, in: destinationFD)
        guard result == 0 else { throw ArchivePublication.error(result, path: output.lastPathComponent) }
    }

    private static func writeZIP(
        _ sources: [(URL, stat)], to fd: Int32, password: String?, destination: ArchivePublication.Identity,
        directoryListed: (String) throws -> Void
    ) throws {
        guard let writer = archive_write_new() else { throw ToolError.invalid("Could not allocate the ZIP writer.") }
        var finalized = false
        defer {
            if !finalized { archive_write_fail(writer) }
            archive_write_free(writer)
        }
        try check(archive_write_set_format_zip(writer), writer)
        if let password, !password.isEmpty {
            try check(archive_write_set_passphrase(writer, password), writer)
            try check(archive_write_set_format_option(writer, "zip", "encryption", "aes256"), writer)
        }
        try check(archive_write_open_fd(writer, fd), writer)
        let names = try uniqueZIPRootNames(sources.map { $0.0.lastPathComponent })
        var paths = ArchivePaths()
        var count = 0
        for ((input, original), name) in zip(sources, names) {
            try appendZIPMember(in: AT_FDCWD, named: input.path, parts: [name],
                                expected: original, destination: destination, writer: writer, paths: &paths, count: &count,
                                directoryListed: directoryListed)
        }
        try Task.checkCancellation()
        try check(archive_write_close(writer), writer)
        finalized = true
    }

    private static func uniqueZIPRootNames(_ names: [String]) throws -> [String] {
        var reserved = Set(names.map(ArchivePaths.collisionKey))
        var used = Set<String>()
        var nextIndex: [String: Int] = [:]
        return try names.map { name in
            try Task.checkCancellation()
            guard try ArchivePaths.components(name) == [name] else {
                throw ToolError.invalid("This item has an unsupported ZIP path: \(name)")
            }
            let key = ArchivePaths.collisionKey(name)
            guard !used.insert(key).inserted else { return name }

            let source = name as NSString
            var index = nextIndex[key, default: 2]
            while index <= 100_000 {
                try Task.checkCancellation()
                let candidate = availableName(stem: source.deletingPathExtension, extension: source.pathExtension, index: index)
                index += 1
                if reserved.insert(ArchivePaths.collisionKey(candidate)).inserted {
                    nextIndex[key] = index
                    return candidate
                }
            }
            throw ToolError.invalid("Could not find an available name for \(name).")
        }
    }

    private static func appendZIPMember(
        in parent: Int32, named name: String, parts: [String], expected: stat? = nil,
        destination: ArchivePublication.Identity, writer: OpaquePointer, paths: inout ArchivePaths, count: inout Int,
        directoryListed: (String) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let path = parts.joined(separator: "/")
        guard try ArchivePaths.components(path) == parts, !parts.isEmpty else {
            throw ToolError.invalid("This item has an unsupported ZIP path: \(path)")
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ArchivePublication.error(errno, path: path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ArchivePublication.error(errno, path: path) }
        guard ArchivePublication.Identity(info) != destination else {
            throw ToolError.invalid("The ZIP destination moved inside a folder being archived.")
        }
        let original = expected ?? info
        try verifyZIPSource(fd, in: parent, named: name, original: original, path: path)
        let directory = info.st_mode & S_IFMT == S_IFDIR
        guard directory || info.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Only regular files and folders can be added: \(path)")
        }
        _ = try paths.insert(parts, directory: directory)
        count += 1
        guard count < 100_000 else { throw ToolError.invalid("A ZIP may contain fewer than 100,000 entries.") }
        try writeZIPEntry(path, directory: directory, size: info.st_size, input: fd, writer: writer)
        if directory {
            let children = try zipChildren(in: fd, path: path, limit: 100_000 - count)
            try directoryListed(path)
            try verifyZIPSource(fd, in: parent, named: name, original: original, path: path)
            for child in children {
                try appendZIPMember(in: fd, named: child, parts: parts + [child],
                                    destination: destination, writer: writer, paths: &paths, count: &count, directoryListed: directoryListed)
            }
        }
        try verifyZIPSource(fd, in: parent, named: name, original: original, path: path)
    }

    private static func zipChildren(in fd: Int32, path: String, limit: Int) throws -> [String] {
        let descriptor = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw ArchivePublication.error(errno, path: path) }
        guard let directory = fdopendir(descriptor) else {
            let issue = errno
            close(descriptor)
            throw ArchivePublication.error(issue, path: path)
        }
        defer { closedir(directory) }

        var children: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw ArchivePublication.error(errno, path: path) }
                return children.sorted()
            }
            let length = Int(entry.pointee.d_namlen)
            guard let name = withUnsafeBytes(of: &entry.pointee.d_name, { String(bytes: $0.prefix(length), encoding: .utf8) })
            else { throw ToolError.invalid("A file in \(path) has an unreadable name.") }
            if name == "." || name == ".." { continue }
            guard children.count + 1 < limit else {
                throw ToolError.invalid("A ZIP may contain fewer than 100,000 entries.")
            }
            children.append(name)
        }
    }

    private static func verifyZIPSource(
        _ fd: Int32, in parent: Int32, named name: String, original: stat, path: String
    ) throws {
        var opened = stat()
        var located = stat()
        guard fstat(fd, &opened) == 0, fstatat(parent, name, &located, AT_SYMLINK_NOFOLLOW) == 0,
              sameZIPSource(opened, as: original), sameZIPSource(located, as: original)
        else { throw ToolError.invalid("Source changed while creating the ZIP: \(path)") }
    }

    private static func sameZIPSource(_ item: stat, as original: stat) -> Bool {
        item.st_dev == original.st_dev && item.st_ino == original.st_ino
            && item.st_mode == original.st_mode && item.st_size == original.st_size
            && item.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec
            && item.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec
            && item.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec
            && item.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
    }

    private static func writeZIPEntry(
        _ path: String, directory: Bool, size: Int64, input: Int32, writer: OpaquePointer
    ) throws {
        guard let entry = archive_entry_new() else { throw ToolError.invalid("Could not allocate the ZIP entry.") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, directory ? path + "/" : path)
        archive_entry_set_filetype(entry, UInt32(directory ? S_IFDIR : S_IFREG))
        archive_entry_set_perm(entry, directory ? 0o755 : 0o644)
        archive_entry_set_size(entry, directory ? 0 : size)
        try check(archive_write_header(writer, entry), writer)
        if !directory {
            try copyToZIP(input, size: size, path: path, writer: writer)
        }
        try check(archive_write_finish_entry(writer), writer)
    }

    private static func copyToZIP(_ input: Int32, size: Int64, path: String, writer: OpaquePointer) throws {
        var remaining = size
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while remaining > 0 {
            try Task.checkCancellation()
            let length = min(buffer.count, Int(remaining))
            let bytes = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, length) }
            if bytes < 0 && errno == EINTR { continue }
            guard bytes > 0 else { throw ToolError.invalid("Source file changed or could not be read: \(path)") }
            let written = buffer.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, bytes) }
            guard written == bytes else { throw archiveError(writer) }
            remaining -= Int64(bytes)
        }
    }
}
