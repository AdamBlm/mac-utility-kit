import AppKit
import UniformTypeIdentifiers

@MainActor
package enum ClipboardFiles {
    package static func read(from board: NSPasteboard, allowedTypes: [UTType]) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: allowedTypes.map(\.identifier)
        ]
        return (board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { file in
                let host = file.host()?.lowercased() ?? ""
                guard file.isFileURL, host.isEmpty || host == "localhost",
                      file.user() == nil, file.password() == nil, file.port == nil,
                      file.query() == nil, file.fragment() == nil else { return false }
                return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
    }
}
