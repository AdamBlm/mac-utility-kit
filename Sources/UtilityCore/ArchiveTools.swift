import CSystemArchive
import Darwin
import Foundation

public struct ArchiveEntry: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        let ordinal: Int
        let path: String
        let directory: Bool
    }

    public let id: ID
    public var path: String { id.path }
    public let isDirectory: Bool
    public let uncompressedSize: Int64?
    public let isEncrypted: Bool
}

public enum ArchiveConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case skip = "Skip"
    case rename = "Rename"

    public var id: Self { self }
}

public struct ArchiveExtractionSummary: Sendable {
    public let published: [URL]
    public let skipped: [String]
    public let renamed: [String: String]
}

public enum ArchiveTools {
    public static func list(_ archive: URL, password: String? = nil) async throws -> [ArchiveEntry] {
        try withReader(archive, password: password) { reader in
            var entries: [ArchiveEntry] = []
            try visit(reader) { entry in
                entries.append(entry)
                try check(archive_read_data_skip(reader), reader)
            }
            return entries
        }
    }

    public static func extract(
        _ archive: URL, to destination: URL, selected: Set<ArchiveEntry.ID>? = nil,
        password: String? = nil, conflicts: ArchiveConflictPolicy
    ) async throws -> ArchiveExtractionSummary {
        guard destination.isFileURL else { throw ToolError.invalid("Choose a local destination folder.") }
        guard selected?.isEmpty != true else { throw ToolError.invalid("Choose at least one archive entry.") }
        let destinationFD = try ArchivePublication.directory(destination)
        defer { close(destinationFD) }
        let staging = try ArchiveStage(in: destinationFD)
        defer { staging.remove() }
        var remaining = selected ?? []
        var folderPrefixes = Set<String>()
        var total: Int64 = 0
        var topLevel = Set<String>()
        // Directory entries can appear after their children, so selection is
        // matched against paths during the same scan used to build the list.
        if let selected {
            folderPrefixes = Set(selected.lazy.filter(\.directory).map { $0.path + "/" })
        }
        try withReader(archive, password: password) { reader in
            try visit(reader) { entry in
                let requested = remaining.remove(entry.id) != nil
                let parts = entry.path.split(separator: "/").map(String.init)
                var prefix = ""
                let includesAncestor = parts.dropLast().contains { component in
                    prefix += component + "/"
                    return folderPrefixes.contains(prefix)
                }
                guard selected == nil || requested || includesAncestor else {
                    try check(archive_read_data_skip(reader), reader)
                    return
                }
                try staging.withParent(of: parts) { parent, name in
                    if entry.isDirectory {
                        let directory = try ArchiveStage.openDirectory(name, in: parent)
                        close(directory)
                        try check(archive_read_data_skip(reader), reader)
                    } else {
                        try writeMember(reader, to: name, in: parent, total: &total)
                    }
                }
                if let root = parts.first { topLevel.insert(root) }
            }
        }
        guard remaining.isEmpty else { throw ToolError.invalid("Archive entries changed. Read the contents again.") }
        try Task.checkCancellation()
        return try publish(topLevel.sorted(), from: staging.fd, to: destination,
                           destinationFD: destinationFD, conflicts: conflicts)
    }

    private static func writeMember(_ reader: OpaquePointer, to name: String, in parent: Int32, total: inout Int64) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ArchivePublication.error(errno, path: name) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            try Task.checkCancellation()
            let bytes = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
            if bytes == 0 { break }
            if bytes < 0 { throw archiveError(reader) }
            total += Int64(bytes)
            guard total <= 32 * 1024 * 1024 * 1024 else {
                throw ToolError.invalid("Selected entries expand beyond the 32 GB extraction limit.")
            }
            try output.write(contentsOf: buffer.prefix(bytes))
        }
        try output.close()
    }

    private static func publish(
        _ names: [String], from stageFD: Int32, to destination: URL, destinationFD: Int32, conflicts: ArchiveConflictPolicy
    ) throws -> ArchiveExtractionSummary {
        var published: [(source: String, destination: String, identity: ArchivePublication.Identity)] = []
        var skipped: [String] = []
        do {
            for name in names {
                try Task.checkCancellation()
                let identity = try ArchivePublication.identity(name, in: stageFD)
                let result = try publishItem(name, from: stageFD, to: destinationFD, conflicts: conflicts)
                if let result { published.append((name, result, identity)) } else { skipped.append(name) }
            }
        } catch {
            var recovery: [String] = []
            for item in published.reversed() {
                let identity = try? ArchivePublication.identity(item.destination, in: destinationFD)
                if identity != item.identity
                    || ArchivePublication.move(item.destination, from: destinationFD, to: item.source, in: stageFD) != 0 {
                    recovery.append(item.destination)
                }
            }
            if !recovery.isEmpty {
                throw ToolError.invalid("Extraction stopped. Some extracted items remain in the destination: \(recovery.joined(separator: ", ")).")
            }
            throw error
        }
        let renamed = Dictionary(uniqueKeysWithValues: published.compactMap {
            $0.source == $0.destination ? nil : ($0.source, $0.destination)
        })
        return ArchiveExtractionSummary(published: published.map { destination.appending(path: $0.destination) },
                                        skipped: skipped, renamed: renamed)
    }

    private static func publishItem(
        _ name: String, from sourceFD: Int32, to destinationFD: Int32, conflicts: ArchiveConflictPolicy
    ) throws -> String? {
        let fileExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for index in 1...10_000 {
            try Task.checkCancellation()
            let candidate = if index == 1 { name } else {
                availableName(stem: stem, extension: fileExtension, index: index)
            }
            let result = ArchivePublication.move(name, from: sourceFD, to: candidate, in: destinationFD)
            if result == 0 { return candidate }
            if result != EEXIST { throw ArchivePublication.error(result, path: candidate) }
            if conflicts == .skip { return nil }
        }
        throw ToolError.invalid("Could not find an available name for \(name).")
    }

    private static func availableName(stem: String, extension fileExtension: String, index: Int) -> String {
        let suffix = " (\(index))"
        let maximumBytes = Int(NAME_MAX)
        let extensionPart = fileExtension.isEmpty ? "" : "." + fileExtension
        let safeExtension = extensionPart.utf8.count + suffix.utf8.count < maximumBytes - 1 ? extensionPart : ""
        let limit = maximumBytes - suffix.utf8.count - safeExtension.utf8.count
        var shortened = ""
        var count = 0
        for character in stem {
            let bytes = character.utf8.count
            if count + bytes > limit { break }
            shortened.append(character)
            count += bytes
        }
        return shortened + suffix + safeExtension
    }

    private static func withReader<T>(
        _ input: URL, password: String?, _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        guard input.isFileURL else { throw ToolError.invalid("Choose a local archive file.") }
        let fd = open(input.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ArchivePublication.error(errno, path: input.lastPathComponent) }
        defer { close(fd) }
        guard let reader = archive_read_new() else { throw ToolError.invalid("Could not allocate the archive reader.") }
        defer { archive_read_free(reader) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Choose a regular archive file.")
        }
        try check(archive_read_support_filter_gzip(reader), reader)
        try check(archive_read_support_filter_bzip2(reader), reader)
        try check(archive_read_support_filter_xz(reader), reader)
        try check(archive_read_support_format_zip(reader), reader)
        try check(archive_read_support_format_7zip(reader), reader)
        try check(archive_read_support_format_rar(reader), reader)
        try check(archive_read_support_format_rar5(reader), reader)
        try check(archive_read_support_format_tar(reader), reader)
        if let password, !password.isEmpty {
            guard !password.utf8.contains(0) else { throw ToolError.invalid("The archive password contains an invalid character.") }
            try check(archive_read_add_passphrase(reader, password), reader)
        }
        try check(archive_read_open_fd(reader, fd, 128 * 1024), reader)
        return try operation(reader)
    }

    private static func visit(_ reader: OpaquePointer, _ member: (ArchiveEntry) throws -> Void) throws {
        var paths = ArchivePaths()
        for ordinal in 0..<100_000 {
            try Task.checkCancellation()
            var raw: OpaquePointer?
            let status = archive_read_next_header(reader, &raw)
            if status == ARCHIVE_EOF { return }
            try check(status, reader)
            guard let raw, let name = archive_entry_pathname_utf8(raw) ?? archive_entry_pathname(raw),
                  let path = String(validatingCString: name) else {
                throw ToolError.invalid("An archive entry has an unreadable file name.")
            }
            let type = archive_entry_filetype(raw)
            let directory = type == S_IFDIR
            guard (directory || type == S_IFREG), archive_entry_hardlink(raw) == nil, archive_entry_symlink(raw) == nil else {
                throw ToolError.invalid("Archive entry \(path) is a link or unsupported file type.")
            }
            let components = try ArchivePaths.components(path)
            if directory && components.isEmpty {
                try check(archive_read_data_skip(reader), reader)
                continue
            }
            guard !components.isEmpty else { throw ToolError.invalid("An archive entry has no file name.") }
            let relative = try paths.insert(components, directory: directory)
            let size = archive_entry_size_is_set(raw) == 1 ? archive_entry_size(raw) : nil
            try member(ArchiveEntry(id: .init(ordinal: ordinal, path: relative, directory: directory), isDirectory: directory,
                                    uncompressedSize: size, isEncrypted: archive_entry_is_encrypted(raw) != 0))
        }
        throw ToolError.invalid("An archive may contain fewer than 100,000 entries.")
    }

    static func check(_ status: Int32, _ archive: OpaquePointer) throws {
        if status != ARCHIVE_OK { throw archiveError(archive) }
    }

    static func archiveError(_ archive: OpaquePointer) -> ToolError {
        let reason = archive_error_string(archive).flatMap { String(validatingCString: $0) }
        return .invalid(reason ?? "The archive is corrupt, encrypted, or unsupported.")
    }

}
