import Darwin
import Foundation

public struct DiskSpeedOptions: Equatable, Sendable {
    public var sizeMiB = 256
    public var repeats = false

    public init() {}
}

public struct DiskSpeedProgress: Sendable {
    public enum Phase: String, Sendable { case write = "Writing", read = "Reading" }
    public let phase: Phase
    public let pass: Int
    public let passes: Int
    public let fraction: Double
}

public struct DiskSpeedResult: Sendable {
    public struct Pass: Sendable {
        public let writeMegabytesPerSecond: Double
        public let readMegabytesPerSecond: Double
    }
    public let sizeMiB: Int
    public let passes: [Pass]
    public let bypassedFileCache: Bool
    public let fullFlush: Bool

    public var writeMegabytesPerSecond: Double { median(passes.map(\.writeMegabytesPerSecond)) }
    public var readMegabytesPerSecond: Double { median(passes.map(\.readMegabytesPerSecond)) }

    package func passDetails(locale: Locale = .current) -> [String] {
        guard passes.count > 1 else { return [] }
        let rate = FloatingPointFormatStyle<Double>.number.locale(locale).precision(.fractionLength(1))
        return passes.enumerated().map { index, pass in
            let write = pass.writeMegabytesPerSecond.formatted(rate)
            let read = pass.readMegabytesPerSecond.formatted(rate)
            return "Pass \(index + 1) · Write \(write) MB/s · Read \(read) MB/s"
        }
    }

    private func median(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        return ordered[ordered.count / 2]
    }
}

public struct DiskSpeedDestination: Sendable {
    public let availableBytes: UInt64?
    public let isReadOnly: Bool
    public let canWriteFolder: Bool

    public func issue(forSizeMiB size: Int) -> String? {
        guard (1...4_096).contains(size) else { return "Choose a test size between 1 and 4,096 MiB." }
        if isReadOnly { return "The volume is read-only." }
        if !canWriteFolder { return "The test folder is not writable." }
        if let availableBytes, availableBytes < UInt64(size) * 1_048_576 {
            return "There is not enough free space for the selected test size."
        }
        return nil
    }
}

public enum DiskSpeed {
    @concurrent
    public static func inspect(_ folder: URL) async throws -> DiskSpeedDestination {
        try Task.checkCancellation()
        let (_, directory) = try openFolder(folder)
        defer { close(directory) }
        let result = try destination(directory)
        try Task.checkCancellation()
        return result
    }

    public static func run(
        in folder: URL, options: DiskSpeedOptions,
        progress: @escaping @Sendable (DiskSpeedProgress) async -> Void = { _ in }
    ) async throws -> DiskSpeedResult {
        try await run(in: folder, options: options, refill: { arc4random_buf($0, $1) }, progress: progress)
    }

    static func run(
        in folder: URL, options: DiskSpeedOptions,
        refill: @Sendable (UnsafeMutableRawPointer, Int) -> Void,
        progress: @escaping @Sendable (DiskSpeedProgress) async -> Void
    ) async throws -> DiskSpeedResult {
        guard (1...4_096).contains(options.sizeMiB) else {
            throw ToolError.invalid("Choose a test size between 1 and 4,096 MiB.")
        }
        let bytes = Int64(options.sizeMiB) * 1_048_576
        let passes = options.repeats ? 3 : 1
        try Task.checkCancellation()

        let (path, directory) = try openFolder(folder)
        defer { close(directory) }
        var identity = stat()
        guard fstat(directory, &identity) == 0 else { throw ioError("Could not identify the test volume") }
        if let issue = try destination(directory).issue(forSizeMiB: options.sizeMiB) {
            throw ToolError.invalid(issue)
        }

        let name = ".MacUtilityKit-DiskTest-\(UUID().uuidString)"
        let descriptor = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ioError("Could not create a temporary file in this folder") }
        var unlinked = false
        defer {
            close(descriptor)
            if !unlinked { _ = unlinkat(directory, name, 0) }
        }
        // Unlink the name while retaining the open file descriptor. The volume
        // reclaims the scratch data when the descriptor closes, even on exit.
        guard unlinkat(directory, name, 0) == 0 else {
            throw ioError("Could not safely unlink the temporary test file")
        }
        unlinked = true
        let uncached = fcntl(descriptor, F_NOCACHE, 1) == 0
        let chunk = 1_048_576
        let writeBuffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { writeBuffer.deallocate() }
        let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { readBuffer.deallocate() }

        var measured: [DiskSpeedResult.Pass] = []
        var fullFlush = true
        for pass in 1...passes {
            try Task.checkCancellation()
            try checkVolume(path, identity: identity)
            guard ftruncate(descriptor, 0) == 0 else { throw ioError("Could not reset the temporary file") }
            await progress(.init(phase: .write, pass: pass, passes: passes, fraction: 0))
            try checkVolume(path, identity: identity)
            var elapsed = Duration.zero
            for index in 0..<options.sizeMiB {
                try Task.checkCancellation()
                let offset = Int64(index) * Int64(chunk)
                // Refill before timing so each write has fresh data and measures storage I/O.
                refill(writeBuffer, chunk)
                writeBuffer.storeBytes(of: UInt64(index) ^ (UInt64(pass) << 32), as: UInt64.self)
                let start = ContinuousClock.now
                try transfer(descriptor, buffer: writeBuffer, offset: offset, count: chunk, writing: true)
                elapsed += start.duration(to: .now)
                if index.isMultiple(of: 16) || index == options.sizeMiB - 1 {
                    await progress(.init(phase: .write, pass: pass, passes: passes,
                                         fraction: Double(index + 1) / Double(options.sizeMiB)))
                    try checkVolume(path, identity: identity)
                }
            }
            try Task.checkCancellation()
            let flushStart = ContinuousClock.now
            if fcntl(descriptor, F_FULLFSYNC) != 0 {
                guard fsync(descriptor) == 0 else { throw ioError("Could not flush the write test") }
                fullFlush = false
            }
            elapsed += flushStart.duration(to: .now)
            let write = rate(bytes, elapsed: elapsed)
            try checkVolume(path, identity: identity)
            await progress(.init(phase: .read, pass: pass, passes: passes, fraction: 0))
            try checkVolume(path, identity: identity)
            elapsed = .zero
            for index in 0..<options.sizeMiB {
                try Task.checkCancellation()
                let offset = Int64(index) * Int64(chunk)
                let start = ContinuousClock.now
                try transfer(descriptor, buffer: readBuffer, offset: offset, count: chunk, writing: false)
                elapsed += start.duration(to: .now)
                guard readBuffer.load(as: UInt64.self) == UInt64(index) ^ (UInt64(pass) << 32) else {
                    throw ToolError.invalid("The test file could not be read back correctly.")
                }
                if index.isMultiple(of: 16) || index == options.sizeMiB - 1 {
                    await progress(.init(phase: .read, pass: pass, passes: passes,
                                         fraction: Double(index + 1) / Double(options.sizeMiB)))
                    try checkVolume(path, identity: identity)
                }
            }
            measured.append(.init(writeMegabytesPerSecond: write, readMegabytesPerSecond: rate(bytes, elapsed: elapsed)))
        }
        try Task.checkCancellation()
        return DiskSpeedResult(sizeMiB: options.sizeMiB, passes: measured, bypassedFileCache: uncached, fullFlush: fullFlush)
    }

    private static func openFolder(_ folder: URL) throws -> (path: String, descriptor: Int32) {
        guard folder.isFileURL else { throw ToolError.invalid("Choose a local test folder.") }
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ioError("Could not open the test folder") }
        return (path, descriptor)
    }

    private static func destination(_ directory: Int32) throws -> DiskSpeedDestination {
        var info = statfs()
        guard fstatfs(directory, &info) == 0 else { throw ioError("Could not read available space") }
        // Darwin reports unsupported fields as all ones.
        let bytes: UInt64?
        if info.f_bsize == 0 || info.f_bsize == .max || info.f_bavail == .max {
            bytes = nil
        } else {
            let product = info.f_bavail.multipliedReportingOverflow(by: UInt64(info.f_bsize))
            bytes = product.overflow ? .max : product.partialValue
        }
        return DiskSpeedDestination(availableBytes: bytes,
                                    isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
                                    canWriteFolder: faccessat(directory, ".", W_OK | X_OK, 0) == 0)
    }

    private static func transfer(
        _ descriptor: Int32, buffer: UnsafeMutableRawPointer, offset: Int64, count: Int, writing: Bool
    ) throws {
        var completed = 0
        while completed < count {
            try Task.checkCancellation()
            let position = offset + Int64(completed)
            let pointer = buffer.advanced(by: completed)
            let size = count - completed
            let number = writing
                ? pwrite(descriptor, pointer, size, position)
                : pread(descriptor, pointer, size, position)
            if number < 0, errno == EINTR { continue }
            guard number >= 0 else { throw ioError(writing ? "Write test failed" : "Read test failed") }
            guard number > 0 else { throw ToolError.invalid("The temporary test file ended unexpectedly.") }
            completed += number
        }
    }

    private static func checkVolume(_ path: String, identity: stat) throws {
        var current = stat()
        guard lstat(path, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            throw ToolError.invalid("The selected volume disconnected or the test folder changed.")
        }
    }

    private static func rate(_ bytes: Int64, elapsed: Duration) -> Double {
        let time = elapsed.components
        let seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18
        return Double(bytes) / 1_000_000 / max(seconds, 1e-9)
    }

    private static func ioError(_ action: String) -> ToolError {
        let code = errno
        if [ENXIO, ENODEV, ESTALE].contains(code) {
            return .invalid("The selected volume became unavailable.")
        }
        return .invalid("\(action). \(String(cString: strerror(code)))")
    }
}
