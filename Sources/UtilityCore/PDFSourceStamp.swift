import Darwin
import Foundation

public struct PDFSourceStamp: Equatable, Sendable {
    private let resolved: URL
    private let stamp: DuplicateFileStamp

    public static func read(_ input: URL) throws -> Self {
        let resolved = input.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard input.isFileURL, stat(resolved.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent).")
        }
        return Self(resolved: resolved, stamp: DuplicateFileStamp(metadata))
    }
}
