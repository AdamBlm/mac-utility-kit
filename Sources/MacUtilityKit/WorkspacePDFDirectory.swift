import Foundation
import PDFKit

/// Keeps temporary PDFs available to the reader and its tool handoffs for the workspace's lifetime.
final class WorkspacePDFDirectory {
    let url: URL

    init() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: "MacUtilityKit-WorkspacePDFs-\(UUID())", directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        url = directory
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func stageClipboardPDF(_ data: Data) throws -> URL {
        guard let document = PDFDocument(data: data), document.isLocked || document.pageCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let folder = url.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let output = folder.appending(path: "Clipboard PDF.pdf")
        do {
            try data.write(to: output, options: .atomic)
            return output
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
