import Darwin
import Foundation
import Synchronization

struct VideoCompressionSizes {
    let inputLabel: String
    let sourceBytes: Int64
    let outputBytes: Int64

    init(inputLabel: String, sourceBytes: Int64, output: URL) throws {
        self.inputLabel = inputLabel
        self.sourceBytes = sourceBytes
        outputBytes = Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    var needsReview: Bool { sourceBytes > 0 && outputBytes >= sourceBytes }

    var summary: String {
        guard sourceBytes > 0, outputBytes > 0 else { return inputLabel }
        let change = Double(sourceBytes - outputBytes) / Double(sourceBytes)
        let percent = abs(change).formatted(.percent.precision(.fractionLength(1)))
        let sizeChange = change == 0 ? "Same size" : percent + (change > 0 ? " saved" : " larger")
        let before = ByteCountFormatter.string(fromByteCount: sourceBytes, countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
        return "\(inputLabel) • \(before) → \(after) • \(sizeChange)"
    }
}

/// Owns one unpublished encode until the workspace keeps or discards it.
package final class VideoCompressionReview: Identifiable, Sendable {
    package let id = UUID()
    package let summary: String
    private let folder: URL
    private let published: URL
    private let filename: String
    private let identity: DuplicateFileIdentity
    private let encodedFile: DuplicateFileStamp
    private let resolved = Mutex(false)

    init(staged: URL, destination: URL, summary: String) throws {
        let manager = FileManager.default
        self.summary = summary
        filename = staged.lastPathComponent
        folder = destination.appending(path: ".MacUtilityKit-Video-" + id.uuidString, directoryHint: .isDirectory)
        published = destination.appending(path: "Compress Video - " + id.uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try manager.moveItem(at: staged, to: folder.appending(path: filename))
            let descriptor = try Self.openFolder(folder)
            defer { close(descriptor) }
            identity = try Self.folderIdentity(descriptor)
            encodedFile = try Self.fileStamp(filename, in: descriptor)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    deinit { try? discard() }

    package func keep() throws -> URL {
        try resolved.withLock { resolved in
            guard !resolved else { throw ToolError.invalid("This export was already reviewed.") }
            let descriptor = try openVerifiedFolder()
            defer { close(descriptor) }
            guard (try? Self.fileStamp(filename, in: descriptor)) == encodedFile else {
                throw ToolError.invalid("The pending video is missing or has changed.")
            }
            guard renamex_np(folder.path, published.path, UInt32(RENAME_EXCL)) == 0 else {
                throw Self.posix(errno)
            }
            resolved = true
            return published.appending(path: filename)
        }
    }

    package func discard() throws {
        try resolved.withLock { resolved in
            guard !resolved else { return }
            guard let descriptor = try? openVerifiedFolder() else {
                resolved = true
                return
            }
            defer { close(descriptor) }
            if (try? Self.fileStamp(filename, in: descriptor)) == encodedFile {
                guard unlinkat(descriptor, filename, 0) == 0 || errno == ENOENT else {
                    throw Self.posix(errno)
                }
            }
            if rmdir(folder.path) != 0, errno != ENOTEMPTY, errno != ENOENT {
                throw Self.posix(errno)
            }
            resolved = true
        }
    }

    private func openVerifiedFolder() throws -> Int32 {
        let descriptor = try Self.openFolder(folder)
        do {
            guard try Self.folderIdentity(descriptor) == identity else {
                throw ToolError.invalid("The pending export folder has changed.")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openFolder(_ folder: URL) throws -> Int32 {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix(errno) }
        return descriptor
    }

    private static func folderIdentity(_ descriptor: Int32) throws -> DuplicateFileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posix(errno) }
        return DuplicateFileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func fileStamp(_ name: String, in folder: Int32) throws -> DuplicateFileStamp {
        var metadata = stat()
        guard fstatat(folder, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Could not read the pending video.")
        }
        return DuplicateFileStamp(metadata)
    }

    private static func posix(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
