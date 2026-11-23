import Foundation
import UtilityCore

extension Tool {
    static func workspaceSearchResults(_ query: String) -> [Tool] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return allCases }
        var exact: [Tool] = []
        var titles: [Tool] = []
        var related: [Tool] = []
        for tool in allCases {
            if tool.title.compare(search, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedSame {
                exact.append(tool)
            } else if tool.title.localizedStandardContains(search) {
                titles.append(tool)
            } else if tool.matchesWorkspaceSearch(search) {
                related.append(tool)
            }
        }
        return exact + titles + related
    }

    func matchesWorkspaceSearch(_ search: String) -> Bool {
        if title.localizedStandardContains(search) || category.localizedStandardContains(search) { return true }
        let capabilities: [String] = switch self {
        case .mergePDFs: ["Combine PDFs", "Join PDFs"]
        case .rotateImages: ["Crop Images", "Image Crop"]
        case .organizePDF: ["Add PDF Page Numbers", "PDF Numbering"]
        case .compressPDF: ["PDF Compress", "PDF Compression", "Reduce PDF Size"]
        default: []
        }
        return capabilities.contains { $0.localizedStandardContains(search) }
    }
}
