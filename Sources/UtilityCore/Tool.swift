import UniformTypeIdentifiers

public enum Tool: String, CaseIterable, Identifiable, Sendable {
    case resizeImages, mergePDFs, compressVideo

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .resizeImages: "Resize Images"
        case .mergePDFs: "Merge PDFs"
        case .compressVideo: "Compress Video"
        }
    }

    public var category: String {
        switch self {
        case .resizeImages: "Images"
        case .mergePDFs: "Documents"
        case .compressVideo: "Video"
        }
    }

    public var inputTypes: [UTType] {
        switch self {
        case .resizeImages: [.image]
        case .mergePDFs: [.pdf, .image]
        case .compressVideo: [.movie]
        }
    }
}
