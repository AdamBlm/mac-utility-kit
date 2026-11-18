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
            .filter { $0.isFileURL && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}
