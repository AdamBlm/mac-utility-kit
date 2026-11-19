import Foundation

/// Keeps merge previews available to the reader and its tool handoffs for the workspace's lifetime.
final class PDFMergePreviewDirectory {
    let url: URL

    init() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: "MacUtilityKit-MergePreviews-\(UUID())", directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        url = directory
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
