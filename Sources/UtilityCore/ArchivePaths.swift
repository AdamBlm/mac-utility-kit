import Darwin
import Foundation

struct ArchivePaths {
    private var members: [String: Member] = [:]

    private struct Member {
        let path: String
        let directory: Bool
        var explicit: Bool
    }

    static func components(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              path.utf8.count <= 4096 else { throw unsafe(path) }
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard parts.count <= 128, parts.allSatisfy({ $0 != ".." && $0.utf8.count <= 255 }) else {
            throw unsafe(path)
        }
        return parts
    }

    static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    mutating func insert(_ parts: [String], directory: Bool) throws -> String {
        let path = parts.joined(separator: "/")
        var prefix = ""
        for (index, name) in parts.enumerated() {
            prefix += index == 0 ? name : "/" + name
            let final = index == parts.count - 1
            let key = Self.collisionKey(prefix)
            if var previous = members[key] {
                guard previous.path == prefix, previous.directory, !final || (directory && !previous.explicit) else {
                    throw ToolError.invalid("Archive paths conflict at \(prefix).")
                }
                if final {
                    previous.explicit = true
                    members[key] = previous
                }
                continue
            } else if members.count >= 250_000 {
                throw ToolError.invalid("The archive contains too many paths.")
            }
            members[key] = Member(path: prefix, directory: !final || directory, explicit: final)
        }
        return path
    }

    private static func unsafe(_ path: String) -> ToolError {
        .invalid("Unsafe archive path: \(path)")
    }
}

enum ArchivePublication {
    struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ information: stat) {
            device = information.st_dev
            inode = information.st_ino
        }
    }

    static func identity(_ name: String, in directory: Int32) throws -> Identity {
        var details = stat()
        guard fstatat(directory, name, &details, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw error(errno, path: name)
        }
        return Identity(details)
    }

    static func directoryLineage(_ directory: Int32) throws -> Set<Identity> {
        var seen = Set<Identity>()
        var current = directory
        defer { if current != directory { close(current) } }
        while true {
            let ancestor = try identity(".", in: current)
            if !seen.insert(ancestor).inserted { return seen }
            let parent = openat(current, "..", O_DIRECTORY | O_RDONLY | O_CLOEXEC)
            guard parent >= 0 else { throw error(errno, path: "Archive destination") }
            if current != directory { close(current) }
            current = parent
        }
    }

    static func move(_ source: String, from sourceFD: Int32, to destination: String, in destinationFD: Int32) -> Int32 {
        if renameatx_np(sourceFD, source, destinationFD, destination, UInt32(RENAME_EXCL)) == 0 { return 0 }
        return errno
    }

    static func directory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw error(errno, path: url.path) }
        return fd
    }

    static func error(_ code: Int32, path: String) -> ToolError {
        let reason = String(cString: strerror(code))
        return .invalid("\(path): \(reason)")
    }
}
