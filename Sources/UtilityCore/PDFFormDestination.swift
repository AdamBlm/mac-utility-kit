import Darwin
import Foundation

package struct PDFFormDestination: Sendable {
    private let parent: URL
    private let parentIdentity: DuplicateFileIdentity
    private let name: String
    private let existing: DuplicateFileStamp?
    package var url: URL { parent.appendingPathComponent(name) }

    package init(_ destination: URL, preserving source: URL, allowsReplacement: Bool = true) throws {
        guard destination.isFileURL else { throw ToolError.invalid("Choose a local destination.") }
        parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              parent.appending(path: name).path != source.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ToolError.invalid("Choose a different filename to preserve the source PDF.")
        }
        let fd = try Self.openParent(parent)
        defer { close(fd) }
        parentIdentity = try Self.identity(fd)
        existing = try Self.file(named: name, in: fd)
        guard allowsReplacement || existing == nil else {
            throw ToolError.invalid("Choose a new local PDF filename.")
        }
    }

    package func publish(_ data: Data) throws {
        try publish { try $0.write(contentsOf: data) }
    }

    package func publish(file: URL) throws {
        try publish { output in
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
        }
    }

    private func publish(write: (FileHandle) throws -> Void) throws {
        try Task.checkCancellation()
        let fd = try Self.openParent(parent)
        defer { close(fd) }
        guard try Self.identity(fd) == parentIdentity else {
            throw ToolError.invalid("The destination folder changed. Choose it again.")
        }

        let temporary = ".muk-form-" + UUID().uuidString
        let output = openat(fd, temporary, O_WRONLY | O_NOFOLLOW | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Self.posix(errno) }
        defer { _ = unlinkat(fd, temporary, 0) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        try write(handle)
        try handle.close()
        try Task.checkCancellation()

        guard try Self.file(named: name, in: fd) == existing else {
            throw ToolError.invalid("The destination file changed. Choose it again before exporting.")
        }
        let status = existing == nil
            ? renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL))
            : renameat(fd, temporary, fd, name)
        guard status == 0 else { throw Self.posix(errno) }
    }

    private static func openParent(_ parent: URL) throws -> Int32 {
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posix(errno) }
        return fd
    }

    private static func identity(_ fd: Int32) throws -> DuplicateFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posix(errno) }
        return DuplicateFileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func file(named name: String, in parent: Int32) throws -> DuplicateFileStamp? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            let error = errno
            if error == ENOENT { return nil }
            throw posix(error)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Choose a regular PDF file, without a symbolic link.")
        }
        return DuplicateFileStamp(info)
    }

    private static func posix(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
