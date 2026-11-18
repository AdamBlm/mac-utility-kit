import UniformTypeIdentifiers

public enum ToolCategory: String, CaseIterable, Identifiable, Sendable {
    case images = "Images"
    case documents = "Documents"
    case video = "Video"
    case audio = "Audio"
    case text = "Text"
    case files = "Files"
    case mac = "Mac"
    case developer = "Developer"

    public var id: Self { self }
    public var title: String { rawValue }
}

public enum Tool: String, CaseIterable, Identifiable, Sendable {
    case resizeImages, mergePDFs, compressVideo, convertVideo, mediaInfo, extractAudio
    case convertImages, compressImages, removeMetadata

    case splitPDF, organizePDF, deletePDFPages, extractPDFPages, imagesToPDF, pdfToImages

    case signPDF, extractText, wordCounter
    case qrCode, batchRename, keepAwake, jsonFormatter, base64, hashGenerator
    case changeSpeed, extractFrames, trimVideo, muteVideo, resizeVideo, videoToGIF, cropRotateVideo, mergeVideos, replaceAudio, burnSubtitles
    case trimAudio

    public var usesInteractiveEditor: Bool {
        switch self {
        case .wordCounter, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator: true
        default: false
        }
    }

    public var requiresSinglePDF: Bool {
        switch self {
        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages, .signPDF: true
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
        case .extractPDFPages: "Extract Pages"
        case .imagesToPDF: "Images to PDF"
        case .pdfToImages: "PDF to Images"
        case .signPDF: "Sign PDF"
        case .extractText: "Extract Text"
        case .wordCounter: "Word Counter"
        case .qrCode: "QR Code"
        case .batchRename: "Batch Rename"
        case .keepAwake: "Keep Awake"
        case .jsonFormatter: "JSON Formatter"
        case .base64: "Base64"
        case .hashGenerator: "Hash Generator"
        case .changeSpeed: "Change Speed"
        case .extractFrames: "Extract Frames"
        case .trimVideo: "Trim Video"
        case .muteVideo: "Mute Video"
        case .resizeVideo: "Resize Video"
        case .videoToGIF: "Video to GIF"
        case .cropRotateVideo: "Crop & Rotate Video"
        case .mergeVideos: "Merge Videos"
        case .replaceAudio: "Replace Audio"
        case .burnSubtitles: "Burn In Subtitles"
        case .compressVideo: "Compress Video"
        case .convertVideo: "Convert Video"
        case .mediaInfo: "Media Info"
        case .extractAudio: "Extract Audio"
        case .trimAudio: "Trim Audio"
        }
    }

    public var category: String { group.title }

    public var group: ToolCategory {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata: .images
        case .mergePDFs, .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .imagesToPDF, .pdfToImages, .signPDF: .documents
        case .extractText, .wordCounter: .text
        case .qrCode, .batchRename: .files
        case .keepAwake: .mac
        case .jsonFormatter, .base64, .hashGenerator: .developer
        case .compressVideo, .convertVideo, .mediaInfo, .changeSpeed, .extractFrames, .trimVideo, .muteVideo, .resizeVideo, .videoToGIF, .cropRotateVideo, .mergeVideos, .replaceAudio, .burnSubtitles: .video
        case .extractAudio, .trimAudio: .audio
        }
    }

    public var inputTypes: [UTType] {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata, .imagesToPDF: [.image]
        case .mergePDFs, .extractText: [.pdf, .image]
        case .wordCounter: [.plainText]
        case .qrCode: [.image]
        case .batchRename, .base64, .hashGenerator: [.data]
        case .jsonFormatter: [.json]
        case .keepAwake: []
        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages, .signPDF: [.pdf]
        case .compressVideo, .convertVideo, .extractAudio, .changeSpeed, .extractFrames, .trimVideo, .muteVideo, .resizeVideo, .videoToGIF, .cropRotateVideo, .mergeVideos, .replaceAudio, .burnSubtitles: [.movie]
        case .mediaInfo: [.movie, .audio]
        case .trimAudio: [.audio]
        }
    }
}
