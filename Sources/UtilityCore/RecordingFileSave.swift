import Foundation

enum RecordingFileSave {
    static func copy(_ source: URL, to output: URL) async throws {
        guard source.isFileURL, output.isFileURL, output.standardizedFileURL != source.standardizedFileURL else {
            throw ToolError.invalid("Choose a separate local save location.")
        }
        let manager = FileManager.default
        let folder = output.deletingLastPathComponent().appending(path: ".recording-save-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let candidate = folder.appending(path: output.lastPathComponent)
        try manager.copyItem(at: source, to: candidate)
        try Task.checkCancellation()
        if manager.fileExists(atPath: output.path) {
            _ = try manager.replaceItemAt(output, withItemAt: candidate)
        } else {
            try manager.moveItem(at: candidate, to: output)
        }
    }
}
