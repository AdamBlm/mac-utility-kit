import CSystemArchive
import Darwin

/// Keeps read callbacks cancellable while allowing libarchive to seek to ZIP
/// central directories and 7z headers. The caller owns the regular-file descriptor
/// and keeps this object alive until it has freed the libarchive reader.
final class ArchiveReadFile {
    private static let blockSize = 128 * 1024

    private let fd: Int32
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 1)

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        buffer.deallocate()
    }

    func open(_ reader: OpaquePointer) throws {
        try ArchiveTools.check(archive_read_set_seek_callback(reader) { reader, context, offset, whence in
            let file = Unmanaged<ArchiveReadFile>.fromOpaque(context!).takeUnretainedValue()
            return file.seek(reader, offset, whence)
        }, reader)
        try ArchiveTools.check(archive_read_open2(reader, Unmanaged.passUnretained(self).toOpaque(), nil, {
            reader, context, destination in
            let file = Unmanaged<ArchiveReadFile>.fromOpaque(context!).takeUnretainedValue()
            return file.read(reader, destination)
        }, { _, context, amount in
            let file = Unmanaged<ArchiveReadFile>.fromOpaque(context!).takeUnretainedValue()
            return file.skip(amount)
        }, nil), reader)
    }

    private func read(_ reader: OpaquePointer?, _ destination: UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int {
        destination?.pointee = UnsafeRawPointer(buffer)
        while true {
            if cancelled(reader) { return -1 }
            let bytes = Darwin.read(fd, buffer, Self.blockSize)
            if bytes >= 0 { return bytes }
            let code = errno
            if code == EINTR { continue }
            muk_archive_set_error(reader, code, "Could not read the archive file.")
            return -1
        }
    }

    private func skip(_ amount: Int64) -> Int64 {
        // A zero skip switches libarchive to read-and-discard, where the read
        // callback can report cancellation. The skip callback returns a byte count.
        guard !Task.isCancelled, amount >= Self.blockSize else { return 0 }
        let start = lseek(fd, 0, SEEK_CUR)
        guard start >= 0 else { return 0 }
        let end = lseek(fd, amount, SEEK_CUR)
        return end < 0 ? 0 : end - start
    }

    private func seek(_ reader: OpaquePointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
        if cancelled(reader) { return Int64(ARCHIVE_FATAL) }
        let position = lseek(fd, offset, whence)
        if position >= 0 { return position }
        muk_archive_set_error(reader, errno, "Could not seek in the archive file.")
        return Int64(ARCHIVE_FATAL)
    }

    private func cancelled(_ reader: OpaquePointer?) -> Bool {
        guard Task.isCancelled else { return false }
        muk_archive_set_error(reader, ECANCELED, "Archive reading was canceled.")
        return true
    }
}
