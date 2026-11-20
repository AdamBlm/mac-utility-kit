import Foundation

package enum PlainTextDecoding {
    package enum ReadIssue: LocalizedError {
        case nonLocal, notRegular, tooLarge, changed

        package var errorDescription: String? {
            switch self {
            case .nonLocal: "Choose a local file."
            case .notRegular: "Choose a regular file."
            case .tooLarge: "The file exceeds the input size limit."
            case .changed: "The input file changed while opening it."
            }
        }
    }

    package struct FileVersion: Sendable {
        let stamp: DuplicateFileStamp
    }

    package static func loadVerifiedBytes(_ input: URL, maximumBytes: Int) async throws -> Data {
        try await loadVerifiedFile(input, maximumBytes: maximumBytes).bytes
    }

    package static func loadVerifiedFile(_ input: URL, maximumBytes: Int) async throws -> (bytes: Data, version: FileVersion) {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            guard input.isFileURL else { throw ReadIssue.nonLocal }
            let resolved = input.resolvingSymlinksInPath().standardizedFileURL
            guard let stamp = try DuplicateFileIO.inspect(resolved) else { throw ReadIssue.notRegular }
            guard stamp.bytes <= maximumBytes else { throw ReadIssue.tooLarge }
            var bytes = Data()
            bytes.reserveCapacity(Int(stamp.bytes))
            let file = DuplicateFile(url: resolved, stamp: stamp)
            try DuplicateFileIO.forEachVerifiedChunk(file) { bytes.append($0) }
            try Task.checkCancellation()
            guard input.resolvingSymlinksInPath().standardizedFileURL.path == resolved.path else {
                throw ReadIssue.changed
            }
            return (bytes, FileVersion(stamp: stamp))
        }
        return try await withTaskCancellationHandler {
            let file = try await work.value
            try Task.checkCancellation()
            return file
        } onCancel: {
            work.cancel()
        }
    }

    package static func decode(_ data: Data) -> String? {
        let text: String?
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            guard data.count.isMultiple(of: 4) else { return nil }
            text = String(data: data, encoding: .utf32)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard data.count.isMultiple(of: 2) else { return nil }
            text = String(data: data, encoding: .utf16)
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }
}
