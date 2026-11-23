import Foundation
import UniformTypeIdentifiers

package enum LocalInputFile {
    package struct Version: Equatable, Sendable {
        let resolved: URL
        let stamp: DuplicateFileStamp

        package static func read(_ input: URL) throws -> Self {
            guard let resolved = LocalInputFile.regularFile(input),
                  let stamp = try? DuplicateFileIO.inspect(resolved) else {
                throw ToolError.invalid("Choose a readable local file for \(input.lastPathComponent).")
            }
            return Version(resolved: resolved, stamp: stamp)
        }

        func verify(_ input: URL) throws {
            guard (try? Self.read(input)) == self else {
                throw ToolError.invalid("\(input.lastPathComponent) changed during merging. Try again.")
            }
        }
    }

    package static func matches(_ file: URL, allowedTypes: [UTType]) -> Bool {
        guard let resolved = regularFile(file),
              let type = try? resolved.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return allowedTypes.contains { type.conforms(to: $0) }
    }

    static func isLocalURL(_ file: URL) -> Bool {
        let host = file.host()?.lowercased() ?? ""
        return file.isFileURL && (host.isEmpty || host == "localhost")
            && file.user() == nil && file.password() == nil && file.port == nil
            && file.query() == nil && file.fragment() == nil
    }

    package static func regularFile(_ file: URL) -> URL? {
        guard isLocalURL(file) else { return nil }
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return resolved
    }
}
