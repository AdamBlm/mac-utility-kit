import AppKit
import UtilityCore

struct FinderFileAction {
    let tool: Tool
    let files: [URL]

    init?(serviceID: String, files: [URL]) {
        guard let tool = Tool(rawValue: serviceID) else { return nil }
        let isPDF: Bool
        let allowedCount: ClosedRange<Int>
        switch tool {
        case .compressPDF:
            (isPDF, allowedCount) = (true, 1...Int.max)
        case .organizePDF:
            (isPDF, allowedCount) = (true, 1...1)
        case .mergePDFs:
            (isPDF, allowedCount) = (true, 2...Int.max)
        case .compressImages, .resizeImages, .convertImages:
            (isPDF, allowedCount) = (false, 1...Int.max)
        default:
            return nil
        }
        guard allowedCount.contains(files.count), files.allSatisfy({
            LocalInputFile.matches($0, allowedTypes: isPDF ? [.pdf] : [.image])
        }) else { return nil }
        self.tool = tool
        self.files = files
    }

    @MainActor
    init?(serviceID: String, pasteboard: NSPasteboard) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        self.init(serviceID: serviceID, files: files ?? [])
    }
}
