import Foundation
import PDFKit

/// Keeps temporary PDFs available to the reader and its tool handoffs for the workspace's lifetime.
@MainActor
final class WorkspacePDFDirectory {
    let url: URL
    private var nextClipboardNumber = 1

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
        let output = url.appending(path: "Clipboard PDF \(nextClipboardNumber).pdf")
        try data.write(to: output, options: .atomic)
        nextClipboardNumber += 1
        return output
    }
}
