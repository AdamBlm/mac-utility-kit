import Darwin
import Foundation

public struct PDFSourceStamp: Hashable, Sendable {
    package let resolved: URL
    private let stamp: DuplicateFileStamp

    var bytes: Int64 { stamp.bytes }

    public static func read(_ input: URL) throws -> Self {
        let resolved = input.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard input.isFileURL, stat(resolved.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent).")
        }
        return Self(resolved: resolved, stamp: DuplicateFileStamp(metadata))
    }

    func copyVerified(to output: URL) throws {
        let source = open(resolved.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw changedSource }
        defer { close(source) }
        guard matches(source) else { throw changedSource }

        let destination = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw ToolError.invalid("Could not create the original PDF copy.") }
        defer { close(destination) }
        guard fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
            throw ToolError.invalid("Could not copy the original PDF.")
        }
        guard matches(source) else { throw changedSource }
    }

    private func matches(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
            && DuplicateFileStamp(metadata) == stamp
    }

    private var changedSource: ToolError {
        .invalid("The source PDF changed while copying. Try again.")
    }
}
