import Darwin
import Foundation

extension ByteEncoding {
    package func convertFile(
        _ input: URL, to output: URL, decoding: Bool, padded: Bool, wrapAt: Int,
        expectedSource: PlainTextDecoding.FileVersion? = nil
    ) async throws {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try writeConversion(input, to: output, decoding: decoding, padded: padded, wrapAt: wrapAt,
                                expectedSource: expectedSource)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func writeConversion(
        _ input: URL, to output: URL, decoding: Bool, padded: Bool, wrapAt: Int,
        expectedSource: PlainTextDecoding.FileVersion?
    ) throws {
        guard input.isFileURL, output.isFileURL else { throw ToolError.invalid("Choose local files.") }
        try Task.checkCancellation()
        let descriptor = open(input.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? source.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Choose a regular input file.")
        }
        let stamp = DuplicateFileStamp(info)
        if let expectedSource, expectedSource.stamp != stamp {
            throw ToolError.invalid("The input file changed after preview. Reload the preview before exporting.")
        }
        try validateDestination(output, source: stamp)
        let originalDestination = try destinationStamp(output)

        let manager = FileManager.default
        let folder = output.deletingLastPathComponent().appending(path: ".byte-conversion-\(UUID())")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let staged = folder.appending(path: "result")
        guard manager.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = try FileHandle(forWritingTo: staged)
        defer { try? destination.close() }

        var converter = FileByteConversion(format: self, decoding: decoding, padded: padded, wrapAt: wrapAt)
        var remaining = stamp.bytes
        while remaining > 0 {
            try Task.checkCancellation()
            let consumed = try autoreleasepool {
                guard let bytes = try source.read(upToCount: Int(min(remaining, 64 * 1024))),
                      !bytes.isEmpty else { return 0 }
                try destination.write(contentsOf: converter.consume(bytes))
                return bytes.count
            }
            guard consumed > 0 else { throw ToolError.invalid("The input file changed during conversion.") }
            remaining -= Int64(consumed)
        }
        try destination.write(contentsOf: converter.finish())
        try destination.close()
        try Task.checkCancellation()
        guard fstat(descriptor, &info) == 0, DuplicateFileStamp(info) == stamp,
              stat(input.path, &info) == 0, DuplicateFileStamp(info) == stamp else {
            throw ToolError.invalid("The input file changed during conversion.")
        }
        try validateDestination(output, source: stamp)
        guard try destinationStamp(output) == originalDestination else {
            throw ToolError.invalid("The destination changed during conversion. Choose where to save again.")
        }
        try Task.checkCancellation()
        let status = originalDestination == nil
            ? renamex_np(staged.path, output.path, UInt32(RENAME_EXCL))
            : rename(staged.path, output.path)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: output.path])
        }
    }

    private func destinationStamp(_ url: URL) throws -> DuplicateFileStamp? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return DuplicateFileStamp(info) }
        if errno == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }

    private func validateDestination(_ output: URL, source: DuplicateFileStamp) throws {
        var info = stat()
        if stat(output.path, &info) == 0, DuplicateFileStamp(info).identity == source.identity {
            throw ToolError.invalid("Choose an output file different from the input.")
        }
    }
}

private struct FileByteConversion {
    let format: ByteEncoding
    let decoding: Bool
    let padded: Bool
    let wrapAt: Int
    var pending = Data()
    var column = 0
    var consumedInputBytes = 0

    mutating func consume(_ chunk: Data) throws -> Data {
        if decoding {
            pending.append(contentsOf: try format.filteredDigits(chunk, after: consumedInputBytes))
            consumedInputBytes += chunk.count
            let group = format.supportsPadding ? 4 : format == .hex ? 2 : 8
            // Keep the final padded group until EOF to reject data after padding.
            let padding = format.supportsPadding ? pending.firstIndex(of: 61) : nil
            let prefixCount = padding ?? pending.count
            let count = prefixCount - prefixCount % group
            let result = try format.decodeDigits(Array(pending.prefix(count)))
            pending = Data(pending.dropFirst(count))
            if padding != nil, pending.count > group { throw ByteEncodingError.invalidPadding }
            return result
        }

        pending.append(chunk)
        let count = format.supportsPadding ? pending.count - pending.count % 3 : pending.count
        let text = format.encode(Data(pending.prefix(count)), padded: padded)
        pending = Data(pending.dropFirst(count))
        return wrap(text)
    }

    mutating func finish() throws -> Data {
        if decoding { return try format.decodeDigits(Array(pending)) }
        return wrap(format.encode(pending, padded: padded))
    }

    private mutating func wrap(_ text: String) -> Data {
        guard wrapAt > 0 else { return Data(text.utf8) }
        let bytes = text.utf8
        var result = Data()
        result.reserveCapacity(bytes.count + bytes.count / wrapAt + 1)
        for byte in bytes {
            if column == wrapAt {
                result.append(10)
                column = 0
            }
            result.append(byte)
            column += 1
        }
        return result
    }
}
