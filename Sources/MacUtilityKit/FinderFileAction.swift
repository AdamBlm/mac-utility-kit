import AppKit
import UniformTypeIdentifiers
import UtilityCore

struct FinderFileAction: Identifiable {
    let id = UUID()
    let tool: Tool?
    let files: [URL]

    init?(serviceID: String, files: [URL]) {
        guard !files.isEmpty, files.allSatisfy({
            LocalInputFile.matches($0, allowedTypes: [.pdf, .image])
        }) else { return nil }

        self.files = files
        switch serviceID {
        case "favorites": tool = nil
        case Tool.compressPDF.rawValue: tool = .compressPDF
        case Tool.compressImages.rawValue: tool = .compressImages
        case Tool.mergePDFs.rawValue:
            guard files.allSatisfy({ LocalInputFile.matches($0, allowedTypes: [.pdf]) }) else { return nil }
            tool = .mergePDFs
        default: return nil
        }
        if let tool, !supports(tool) { return nil }
    }

    @MainActor
    init?(serviceID: String, pasteboard: NSPasteboard) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        self.init(serviceID: serviceID, files: files ?? [])
    }

    func compatibleFavorites(_ favorites: [Tool]) -> [Tool] {
        favorites.filter(supports)
    }

    func supports(_ tool: Tool) -> Bool {
        // These interactive editors accept URLs through the workspace draft's inputs.
        if tool.usesInteractiveEditor {
            guard tool == .addPassword || tool == .removePassword, files.count == 1 else { return false }
        }
        if tool.requiresSinglePDF && files.count != 1 { return false }
        if tool == .mergePDFs && files.count < 2 { return false }
        return files.allSatisfy { LocalInputFile.matches($0, allowedTypes: tool.inputTypes) }
    }
}
