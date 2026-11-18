import UniformTypeIdentifiers

public enum ToolCategory: String, CaseIterable, Identifiable, Sendable {
    case images = "Images"
    case documents = "Documents"
    case video = "Video"
    case audio = "Audio"

    public var id: Self { self }
    public var title: String { rawValue }
}

public enum Tool: String, CaseIterable, Identifiable, Sendable {
    case resizeImages, mergePDFs, compressVideo, convertVideo, mediaInfo, extractAudio
    case convertImages, compressImages, removeMetadata

    case splitPDF, organizePDF, deletePDFPages

    public var editsOnePDF: Bool {
        switch self {
        case .splitPDF, .organizePDF, .deletePDFPages: true
        default: false
        }
    }

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .resizeImages: "Resize Images"
        case .convertImages: "Convert Images"
        case .compressImages: "Compress Images"
        case .removeMetadata: "Remove Metadata"
        case .mergePDFs: "Merge PDFs"
        case .splitPDF: "Split PDF"
        case .organizePDF: "Organize PDF"
        case .deletePDFPages: "Delete Pages"
        case .compressVideo: "Compress Video"
        case .convertVideo: "Convert Video"
        case .mediaInfo: "Media Info"
        case .extractAudio: "Extract Audio"
        }
    }

    public var category: String { group.title }

    public var group: ToolCategory {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata: .images
        case .mergePDFs, .splitPDF, .organizePDF, .deletePDFPages: .documents
        case .compressVideo, .convertVideo, .mediaInfo: .video
        case .extractAudio: .audio
        }
    }

    public var inputTypes: [UTType] {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata: [.image]
        case .mergePDFs: [.pdf, .image]
        case .splitPDF, .organizePDF, .deletePDFPages: [.pdf]
        case .compressVideo, .convertVideo, .extractAudio: [.movie]
        case .mediaInfo: [.movie, .audio]
        }
    }
}
