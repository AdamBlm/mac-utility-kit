import CSystemArchive
import Darwin
import Foundation

extension ArchiveTools {
    public static func create(_ inputs: [URL], to output: URL, password: String? = nil) async throws {
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
        let destinationLineage = try ArchivePublication.directoryLineage(destinationFD)
        for input in inputs {
            guard input.isFileURL else { throw ToolError.invalid("Choose local files or folders.") }
            var details = stat()
            guard lstat(input.path, &details) == 0 else {
                throw ArchivePublication.error(errno, path: input.lastPathComponent)
            }
            guard !destinationLineage.contains(ArchivePublication.Identity(details)) else {
                throw ToolError.invalid("Choose a ZIP destination outside the folders being archived.")
            }
        }
        let stage = try ArchiveStage(in: destinationFD)
        defer { stage.remove() }
        let stagedName = "Output.zip"
        let fd = openat(stage.fd, stagedName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ArchivePublication.error(errno, path: output.lastPathComponent) }
        defer { close(fd) }
        try writeZIP(inputs, to: fd, password: password)
        try Task.checkCancellation()
        let result = ArchivePublication.move(stagedName, from: stage.fd,
                                             to: output.lastPathComponent, in: destinationFD)
        guard result == 0 else { throw ArchivePublication.error(result, path: output.lastPathComponent) }
    }

    private static func writeZIP(_ inputs: [URL], to fd: Int32, password: String?) throws {
        guard let writer = archive_write_new() else { throw ToolError.invalid("Could not allocate the ZIP writer.") }
        defer { archive_write_free(writer) }
        try check(archive_write_set_format_zip(writer), writer)
        if let password, !password.isEmpty {
            try check(archive_write_set_passphrase(writer, password), writer)
            try check(archive_write_set_format_option(writer, "zip", "encryption", "aes256"), writer)
        }
        try check(archive_write_open_fd(writer, fd), writer)
        var paths = ArchivePaths()
        var count = 0
        for input in inputs {
            try appendZIPMember(input, parts: [input.lastPathComponent], writer: writer, paths: &paths, count: &count)
        }
        try check(archive_write_close(writer), writer)
    }

    private static func appendZIPMember(
        _ input: URL, parts: [String], writer: OpaquePointer, paths: inout ArchivePaths, count: inout Int
    ) throws {
        try Task.checkCancellation()
        let path = parts.joined(separator: "/")
        guard try ArchivePaths.components(path) == parts, !parts.isEmpty else {
            throw ToolError.invalid("This item has an unsupported ZIP path: \(path)")
        }
        let fd = open(input.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ArchivePublication.error(errno, path: path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ArchivePublication.error(errno, path: path) }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        guard directory || info.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Only regular files and folders can be added: \(path)")
        }
        _ = try paths.insert(parts, directory: directory)
        count += 1
        guard count < 100_000 else { throw ToolError.invalid("A ZIP may contain fewer than 100,000 entries.") }
        try writeZIPEntry(path, directory: directory, size: info.st_size, input: fd, writer: writer)
        if directory {
            let children = try FileManager.default.contentsOfDirectory(atPath: input.path).sorted()
            for child in children {
                try appendZIPMember(input.appending(path: child), parts: parts + [child],
                                    writer: writer, paths: &paths, count: &count)
            }
        }
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
        var final = stat()
        guard fstat(input, &final) == 0, final.st_size == size else {
            throw ToolError.invalid("Source file changed while creating the ZIP: \(path)")
        }
    }
}
