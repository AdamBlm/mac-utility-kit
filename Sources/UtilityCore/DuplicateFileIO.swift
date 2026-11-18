import CryptoKit
import Darwin
import Foundation

struct DuplicateFileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
}

struct DuplicateFileStamp: Equatable, Sendable {
    let identity: DuplicateFileIdentity
    let bytes: Int64
    let allocatedBytes: Int64
    let links: UInt64
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    init(_ info: stat) {
        identity = DuplicateFileIdentity(device: info.st_dev, inode: info.st_ino)
        bytes = info.st_size
        let allocation = info.st_blocks.multipliedReportingOverflow(by: 512)
        allocatedBytes = allocation.overflow ? Int64.max : max(0, allocation.partialValue)
        links = UInt64(info.st_nlink)
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    var modified: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }
}

struct DuplicateReadError: LocalizedError {
    let url: URL
    let details: String
    var errorDescription: String? { details }
}

enum DuplicateFileIO {
    static let prefixSize: Int64 = 64 * 1024
    private static let chunkSize: Int64 = 1024 * 1024

    static func inspect(_ url: URL) throws -> DuplicateFileStamp? {
        var info = stat()
        guard url.isFileURL else { throw DuplicateReadError(url: url, details: "Choose a local file.") }
        guard lstat(url.path, &info) == 0 else { throw posixError(url) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return DuplicateFileStamp(info)
    }

    static func requireReadable(_ url: URL) throws {
        guard access(url.path, R_OK) == 0 else { throw posixError(url) }
    }

    static func check(_ file: DuplicateFile) throws {
        guard file.url.resolvingSymlinksInPath().standardizedFileURL.path == file.url.path,
              try inspect(file.url) == file.stamp else { throw changed(file.url) }
    }

    static func hash(_ file: DuplicateFile, prefixOnly: Bool) throws -> SHA256.Digest {
        let opened = try openVerified(file)
        defer { close(opened) }
        let count = prefixOnly ? min(file.bytes, prefixSize) : file.bytes
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < count {
            try Task.checkCancellation()
            let readCount = Int(min(chunkSize, count - offset))
            hasher.update(data: try read(opened, file: file, offset: offset, count: readCount))
            offset += Int64(readCount)
        }
        try verify(opened, file: file)
        return hasher.finalize()
    }

    static func equal(_ left: DuplicateFile, _ right: DuplicateFile) throws -> Bool {
        guard left.bytes == right.bytes else { return false }
        let a = try openVerified(left)
        defer { close(a) }
        let b = try openVerified(right)
        defer { close(b) }
        var offset: Int64 = 0
        var equal = true
        while equal, offset < left.bytes {
            try Task.checkCancellation()
            let count = Int(min(chunkSize, left.bytes - offset))
            let leftData = try read(a, file: left, offset: offset, count: count)
            let rightData = try read(b, file: right, offset: offset, count: count)
            equal = leftData == rightData
            offset += Int64(count)
        }
        try verify(a, file: left)
        try verify(b, file: right)
        return equal
    }

    private static func openVerified(_ file: DuplicateFile) throws -> Int32 {
        let handle = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard handle >= 0 else { throw posixError(file.url) }
        do {
            try verify(handle, file: file)
            return handle
        } catch {
            close(handle)
            throw error
        }
    }

    private static func verify(_ handle: Int32, file: DuplicateFile) throws {
        var info = stat()
        guard fstat(handle, &info) == 0 else { throw posixError(file.url) }
        guard (info.st_mode & S_IFMT) == S_IFREG, DuplicateFileStamp(info) == file.stamp else {
            throw changed(file.url)
        }
        try check(file)
    }

    private static func read(_ handle: Int32, file: DuplicateFile, offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let bytes = buffer.baseAddress else { return }
            var readCount = 0
            while readCount < count {
                let result = pread(handle, bytes.advanced(by: readCount), count - readCount, offset + Int64(readCount))
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw posixError(file.url) }
                guard result > 0 else { throw changed(file.url) }
                readCount += result
            }
        }
        return data
    }

    private static func changed(_ url: URL) -> DuplicateReadError {
        DuplicateReadError(url: url, details: "The file changed since it was scanned.")
    }

    private static func posixError(_ url: URL) -> DuplicateReadError {
        let code = errno
        let text = String(cString: strerror(code))
        return DuplicateReadError(url: url, details: text)
    }
}
