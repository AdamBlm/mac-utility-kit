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
            guard LocalInputFile.isLocalURL(input) else { throw ReadIssue.nonLocal }
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

    struct Format {
        let encoding: String.Encoding
        let marker: [UInt8]
        let unitBytes: Int

        init(detecting data: Data) {
            let candidates: [(String.Encoding, [UInt8], Int)] = [
                (.utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00], 4),
                (.utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF], 4),
                (.utf16LittleEndian, [0xFF, 0xFE], 2),
                (.utf16BigEndian, [0xFE, 0xFF], 2),
                (.utf8, [0xEF, 0xBB, 0xBF], 1)
            ]
            (encoding, marker, unitBytes) = candidates.first { data.starts(with: $0.1) } ?? (.utf8, [], 1)
        }

        func decode(_ data: Data) -> String? {
            let payload = data.dropFirst(marker.count)
            guard payload.count.isMultiple(of: unitBytes),
                  let text = String(data: payload, encoding: encoding),
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
            return text
        }

        func encode(_ text: String) -> Data? {
            guard let payload = text.data(using: encoding) else { return nil }
            return Data(marker) + payload
        }
    }

    package static func decode(_ data: Data) -> String? {
        Format(detecting: data).decode(data)
    }
}
