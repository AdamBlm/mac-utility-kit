import UniformTypeIdentifiers

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

    public var category: String {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata: "Images"
        case .mergePDFs, .splitPDF, .organizePDF, .deletePDFPages: "Documents"
        case .compressVideo, .convertVideo, .mediaInfo: "Video"
        case .extractAudio: "Audio"
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
