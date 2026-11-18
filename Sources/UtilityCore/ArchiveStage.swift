import Darwin
import Foundation

struct ArchiveStage {
    let fd: Int32

    init(in parent: Int32) throws {
        let name = ".archive-\(UUID().uuidString)"
        guard mkdirat(parent, name, 0o700) == 0 else {
            throw ArchivePublication.error(errno, path: "Archive staging folder")
        }
        do {
            fd = try Self.openDirectory(name, in: parent, create: false)
        } catch {
            _ = unlinkat(parent, name, AT_REMOVEDIR)
            throw error
        }
    }

    func withParent<T>(of path: [String], _ body: (Int32, String) throws -> T) throws -> T {
        guard let name = path.last else { throw ToolError.invalid("An archive entry has no file name.") }
        var current = fd
        defer { if current != fd { close(current) } }
        for component in path.dropLast() {
            let next = try Self.openDirectory(component, in: current)
            if current != fd { close(current) }
            current = next
        }
        return try body(current, name)
    }

    static func openDirectory(_ name: String, in parent: Int32, create: Bool = true) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw ArchivePublication.error(errno, path: name)
        }
        let directory = openat(parent, name, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw ArchivePublication.error(errno, path: name) }
        return directory
    }

    func remove() {
        defer { close(fd) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathStatus = buffer.withUnsafeMutableBufferPointer { pointer in
            fcntl(fd, F_GETPATH, pointer.baseAddress!)
        }
        guard pathStatus == 0,
              let path = String(validating: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self),
              URL(filePath: path).lastPathComponent.hasPrefix(".archive-") else { return }
        var source = stat()
        var located = stat()
        guard fstat(fd, &source) == 0, lstat(path, &located) == 0,
              source.st_ino == located.st_ino, source.st_dev == located.st_dev else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
