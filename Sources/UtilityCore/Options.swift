import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum VideoFormat: String, CaseIterable, Sendable {
    case mp4, mov, m4v

    var fileType: AVFileType {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .m4v: .m4v
        }
    }
}

public enum VideoQuality: String, CaseIterable, Sendable {
    case smaller = "Smaller File"
    case balanced = "Balanced"
    case higher = "Higher Quality"
}

public enum VideoCodec: String, CaseIterable, Sendable {
    case automatic = "Automatic"
    case hevc = "HEVC"
}

public enum ImageSizing: String, CaseIterable, Sendable {
    case longestEdge = "Longest edge"
    case percentage = "Percentage"
    case dimensions = "Width and height"
}

public enum ImageFit: String, CaseIterable, Sendable {
    case fit = "Fit"
    case fill = "Fill"
    case stretch = "Stretch"
}

public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpg, heic, tiff

    var type: UTType {
        switch self {
        case .png: .png
        case .jpg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        }
    }
}

public struct ToolOptions: Sendable {
    public var pdfSignature = PDFSignatureOptions()
    public var textExtraction = TextExtractionOptions()
    public var pdfExtract = PDFExtractOptions()
    public var imagesToPDF = ImagesToPDFOptions()
    public var pdfToImages = PDFToImagesOptions()
    public var pdfSplit = PDFSplitOptions()
    public var pdfOrganize = PDFOrganizeOptions()
    public var pdfDelete = PDFDeleteOptions()
    public var pdfOutputName = "Merged"
    public var pdfPasswords: [String] = []
    public var pageRanges: [String] = []
    public var ffmpegExecutable: URL?
    public var videoFormat: VideoFormat = .mp4
    public var videoCodec: VideoCodec = .automatic
    public var videoQuality: VideoQuality = .balanced
    public var keepLargerVideos = false
    public var conversion = VideoConversionOptions()
    public var speed = ChangeSpeedOptions()
    public var frames = FrameExtractionOptions()
    public var trim = TrimVideoOptions()
    public var mute = MuteVideoOptions()
    public var videoResize = VideoResizeOptions()
    public var videoGIF = VideoGIFOptions()
    public var crop = VideoCropOptions()
    public var videoMerge = VideoMergeOptions()
    public var replaceAudio = ReplaceAudioOptions()
    public var burnSubtitles = BurnSubtitlesOptions()
    public var inspection = MediaInspectionOptions()
    public var extraction = AudioExtractionOptions()
    public var audioTrim = AudioTrimOptions()
    public var audioConvert = AudioConvertOptions()
    public var audioCleanup = AudioCleanupOptions()
    public var imageConversion = ImageConversionOptions()
    public var rotation = ImageRotateOptions()
    public var beautify = BeautifyScreenshotOptions()
    public var blurFaces = BlurFacesOptions()
    public var redactImage = ImageRedactOptions()
    public var removeBackground = RemoveBackgroundOptions()
    public var watermark = WatermarkOptions()
    public var imageCompression = ImageCompressionOptions()
    public var imageMetadata = ImageMetadataOptions()
    public var imageMagickExecutable: URL?
    public var imageSizing: ImageSizing = .longestEdge
    public var imageFit: ImageFit = .fit
    public var imageFormat: ImageFormat = .png
    public var imageWidth = 1600
    public var imageHeight = 900
    public var imagePercentage = 50
    public var upscale = false
    public var imageQuality = 0.85
    public init() {}
}

public enum PageSelection {
    public static func indices(_ expression: String, pageCount: Int) throws -> [Int] {
        let value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.lowercased() == "all" { return Array(0..<pageCount) }
        if value.lowercased() == "none" { return [] }
        var pages: [Int] = []
        var seen: Set<Int> = []
        for token in value.replacingOccurrences(of: "–", with: "-").split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            let numbers = bounds.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == bounds.count, (1...2).contains(numbers.count),
                  let start = numbers.first, let end = numbers.last,
                  start >= 1, end <= pageCount, end >= start else {
                throw ToolError.invalid("Invalid page selection “\(token)”. Enter pages from 1 to \(pageCount).")
            }
            for page in start...end where seen.insert(page).inserted { pages.append(page - 1) }
        }
        return pages
    }
}
