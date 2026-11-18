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
    case convertImages, compressImages, removeMetadata, rotateImages, beautifyScreenshot, blurFaces, screenshot, redactImage, annotateScreenshot, removeBackground, colorPicker, watermark

    case splitPDF, organizePDF, deletePDFPages, extractPDFPages, imagesToPDF, pdfToImages

    case signPDF, extractText, wordCounter, summarize
    case qrCode, batchRename, keepAwake, jsonFormatter, base64, hashGenerator, uuidGenerator, cleanLinks, timestampConverter, loremIpsum, unicodeInspector, diffChecker, regexTester, csvJSON, coordinatePicker, passwordGenerator, batteryHealth, diskSpeedTest, deadPixelTest, ejectAllDisks, presentationMode, findDuplicates, zipUnzip
    case changeSpeed, extractFrames, trimVideo, muteVideo, resizeVideo, videoToGIF, cropRotateVideo, mergeVideos, replaceAudio, burnSubtitles
    case makePDFSearchable, markdownToPDF, webPageToPDF, addPassword, removePassword, compressPDF, cropPDF, redactPDF, convertDocuments, wordToPDF, powerPointToPDF, excelToPDF
    case recordScreen, downloadVideo
    case trimAudio, convertAudio, transcribe, cleanUpAudio, captureText, textToSpeech, recordAudio

    public var officePDFKind: OfficePDFKind? {
        switch self {
        case .wordToPDF: .word
        case .powerPointToPDF: .powerPoint
        case .excelToPDF: .excel
        default: nil
        }
    }

    public var usesInteractiveEditor: Bool {
        switch self {
        case .wordCounter, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .uuidGenerator, .cleanLinks, .timestampConverter, .loremIpsum, .unicodeInspector, .diffChecker, .regexTester, .csvJSON, .coordinatePicker, .passwordGenerator, .batteryHealth, .diskSpeedTest, .deadPixelTest, .ejectAllDisks, .presentationMode, .findDuplicates, .zipUnzip, .summarize, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo, .colorPicker, .markdownToPDF, .webPageToPDF, .addPassword, .removePassword, .redactPDF: true
        default: false
        }
    }

    public var requiresSinglePDF: Bool {
        switch self {
        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages, .signPDF, .cropPDF, .redactPDF: true
        default: false
        }
    }

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .resizeImages: "Resize Images"
        case .convertImages: "Convert Images"
        case .rotateImages: "Rotate Images"
        case .beautifyScreenshot: "Beautify Screenshot"
        case .blurFaces: "Blur Faces"
        case .redactImage: "Redact Image"
        case .screenshot: "Screenshot"
        case .annotateScreenshot: "Annotate Screenshot"
        case .removeBackground: "Remove Background"
        case .colorPicker: "Color Picker"
        case .watermark: "Watermark"
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
        case .makePDFSearchable: "Make PDF Searchable"
        case .compressPDF: "Compress PDF"
        case .cropPDF: "Crop PDF"
        case .convertDocuments: "Convert Documents"
        case .wordToPDF: "Word to PDF"
        case .powerPointToPDF: "PowerPoint to PDF"
        case .excelToPDF: "Excel to PDF"
        case .redactPDF: "Redact PDF"
        case .markdownToPDF: "Markdown to PDF"
        case .webPageToPDF: "Web Page to PDF"
        case .addPassword: "Add Password"
        case .removePassword: "Remove Password"
        case .extractText: "Extract Text"
        case .wordCounter: "Word Counter"
        case .summarize: "Summarize"
        case .transcribe: "Transcribe"
        case .captureText: "Capture Text"
        case .textToSpeech: "Text to Speech"
        case .recordAudio: "Record Audio"
        case .recordScreen: "Record Screen"
        case .downloadVideo: "Download Video"
        case .qrCode: "QR Code"
        case .batchRename: "Batch Rename"
        case .keepAwake: "Keep Awake"
        case .jsonFormatter: "JSON Formatter"
        case .base64: "Base64"
        case .hashGenerator: "Hash Generator"
        case .uuidGenerator: "UUID Generator"
        case .cleanLinks: "Clean Links"
        case .timestampConverter: "Timestamp Converter"
        case .loremIpsum: "Lorem Ipsum"
        case .unicodeInspector: "Unicode Inspector"
        case .diffChecker: "Diff Checker"
        case .regexTester: "Regex Tester"
        case .csvJSON: "CSV ↔ JSON"
        case .coordinatePicker: "Coordinate Picker"
        case .passwordGenerator: "Password Generator"
        case .batteryHealth: "Battery Health"
        case .diskSpeedTest: "Disk Speed Test"
        case .deadPixelTest: "Dead Pixel Test"
        case .ejectAllDisks: "Eject All Disks"
        case .presentationMode: "Presentation Mode"
        case .zipUnzip: "Zip & Unzip"
        case .findDuplicates: "Find Duplicates"
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
        case .convertAudio: "Convert Audio"
        case .cleanUpAudio: "Clean Up Audio"
        }
    }

    public var category: String { group.title }

    public var group: ToolCategory {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata, .rotateImages, .beautifyScreenshot, .blurFaces, .screenshot, .redactImage, .annotateScreenshot, .removeBackground, .colorPicker, .watermark: .images
        case .mergePDFs, .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .imagesToPDF, .pdfToImages, .signPDF, .makePDFSearchable, .markdownToPDF, .webPageToPDF, .addPassword, .removePassword, .compressPDF, .cropPDF, .redactPDF, .convertDocuments, .wordToPDF, .powerPointToPDF, .excelToPDF: .documents
        case .extractText, .wordCounter, .summarize, .transcribe, .captureText, .textToSpeech: .text
        case .qrCode, .batchRename, .findDuplicates, .zipUnzip: .files
        case .keepAwake, .batteryHealth, .diskSpeedTest, .deadPixelTest, .ejectAllDisks, .presentationMode: .mac
        case .jsonFormatter, .base64, .hashGenerator, .uuidGenerator, .cleanLinks, .timestampConverter, .loremIpsum, .unicodeInspector, .diffChecker, .regexTester, .csvJSON, .coordinatePicker, .passwordGenerator: .developer
        case .compressVideo, .convertVideo, .mediaInfo, .changeSpeed, .extractFrames, .trimVideo, .muteVideo, .resizeVideo, .videoToGIF, .cropRotateVideo, .mergeVideos, .replaceAudio, .burnSubtitles, .recordScreen, .downloadVideo: .video
        case .extractAudio, .trimAudio, .convertAudio, .cleanUpAudio, .recordAudio: .audio
        }
    }

    public var inputTypes: [UTType] {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata, .rotateImages, .beautifyScreenshot, .blurFaces, .redactImage, .annotateScreenshot, .removeBackground, .imagesToPDF: [.image]
        case .mergePDFs, .extractText: [.pdf, .image]
        case .watermark: [.image, .pdf, .movie]
        case .wordCounter: [.plainText]
        case .textToSpeech, .summarize: [.plainText, .rtf, .pdf]
        case .excelToPDF:
            ["xls", "xlsx", "ods"].compactMap { UTType(filenameExtension: $0) }
        case .powerPointToPDF:
            ["ppt", "pptx", "odp"].compactMap { UTType(filenameExtension: $0) }
        case .wordToPDF:
            [.rtf, .plainText] + ["doc", "docx", "odt"].compactMap { UTType(filenameExtension: $0) }
        case .convertDocuments:
            [.rtf, .html, .plainText] + ["doc", "docx", "odt", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        case .markdownToPDF: [.plainText]
        case .webPageToPDF, .uuidGenerator, .cleanLinks, .timestampConverter, .loremIpsum, .unicodeInspector, .diffChecker, .regexTester, .csvJSON, .coordinatePicker, .passwordGenerator, .batteryHealth, .diskSpeedTest, .deadPixelTest, .ejectAllDisks, .presentationMode: []
        case .findDuplicates: [.directory]
        case .zipUnzip: [.data, .directory]
        case .qrCode: [.image]
        case .batchRename, .base64, .hashGenerator: [.data]
        case .jsonFormatter: [.json]
        case .keepAwake, .captureText, .recordAudio, .screenshot, .recordScreen, .downloadVideo, .colorPicker: []
        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages, .signPDF, .makePDFSearchable, .addPassword, .removePassword, .compressPDF, .cropPDF, .redactPDF: [.pdf]
        case .compressVideo, .convertVideo, .extractAudio, .changeSpeed, .extractFrames, .trimVideo, .muteVideo, .resizeVideo, .videoToGIF, .cropRotateVideo, .mergeVideos, .replaceAudio, .burnSubtitles: [.movie]
        case .mediaInfo, .transcribe, .cleanUpAudio: [.movie, .audio]
        case .trimAudio, .convertAudio: [.audio]
        }
    }
}
