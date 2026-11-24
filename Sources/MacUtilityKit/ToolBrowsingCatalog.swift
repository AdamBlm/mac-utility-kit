import UtilityCore

struct ToolBrowseSection {
    let title: String
    let tools: [Tool]

    init(_ title: String, _ tools: [Tool]) {
        self.title = title
        self.tools = tools
    }
}

extension ToolCategory {
    /// Colors for this category's hue (the OKLCH hue angle is noted on each `WorkspaceTint` value).
    var workspaceTint: WorkspaceTint {
        switch self {
        case .images: .images
        case .documents: .documents
        case .video: .video
        case .audio: .audio
        case .text: .text
        case .files: .files
        case .mac: .mac
        case .developer: .developer
        }
    }

    var browseSymbol: String {
        switch self {
        case .images: "photo.on.rectangle"
        case .documents: "doc.on.doc"
        case .video: "film"
        case .audio: "waveform"
        case .text: "text.alignleft"
        case .files: "folder"
        case .mac: "desktopcomputer"
        case .developer: "chevron.left.forwardslash.chevron.right"
        }
    }

    var browseSummary: String {
        switch self {
        case .images: "Resize, convert, and edit photos and screenshots."
        case .documents: "Organize PDF pages, convert documents, and fill forms."
        case .video: "Record, trim, compress, and caption video."
        case .audio: "Record, edit, and convert audio."
        case .text: "Extract, transcribe, translate, and edit text."
        case .files: "Rename, organize, and archive files."
        case .mac: "Manage storage, displays, and system settings."
        case .developer: "Format data, compare text, and generate identifiers."
        }
    }

    var browseSections: [ToolBrowseSection] {
        switch self {
        case .images:
            [
                .init("Resize, Convert & Export", [.resizeImages, .convertImages, .compressImages, .removeMetadata]),
                .init("Edit & Protect", [.rotateImages, .removeBackground, .blurFaces, .redactImage, .watermark]),
                .init("Capture & Annotate", [.screenshot, .annotateScreenshot, .beautifyScreenshot, .colorPicker])
            ]
        case .documents:
            [
                .init("Pages", [.mergePDFs, .splitPDF, .organizePDF, .extractPDFPages, .deletePDFPages, .cropPDF]),
                .init("Convert & Compress", [.compressPDF, .imagesToPDF, .pdfToImages, .pdfToWord, .convertDocuments,
                                            .wordToPDF, .powerPointToPDF, .excelToPDF, .markdownToPDF, .webPageToPDF]),
                .init("Scan & Recognize", [.scanDocument, .makePDFSearchable]),
                .init("Sign, Fill & Protect", [.signPDF, .fillFlattenForms, .redactPDF, .addPassword, .removePassword])
            ]
        case .video:
            [
                .init("Edit", [.trimVideo, .mergeVideos, .changeSpeed, .resizeVideo, .cropRotateVideo, .muteVideo, .replaceAudio]),
                .init("Convert & Export", [.compressVideo, .convertVideo, .videoToGIF, .extractFrames, .mediaInfo]),
                .init("Capture & Captions", [.recordScreen, .downloadVideo, .burnSubtitles, .extractSubtitles])
            ]
        case .audio:
            [
                .init("Record & Extract", [.recordAudio, .extractAudio]),
                .init("Edit & Convert", [.trimAudio, .mergeAudio, .cleanUpAudio, .convertAudio])
            ]
        case .text:
            [
                .init("Extract & Transcribe", [.extractText, .captureText, .transcribe]),
                .init("Write & Transform", [.wordCounter, .caseConverter, .batchFindReplace, .translate, .textToSpeech]),
                .init("Read & Analyze", [.summarize, .askDocument])
            ]
        case .files:
            [
                .init("Organize", [.batchRename, .organizeDownloads, .findDuplicates]),
                .init("Share & Archive", [.zipUnzip, .qrCode])
            ]
        case .mac:
            [
                .init("Monitor & Maintain", [.batteryHealth, .diskSpeedTest, .networkSpeedTest, .storageExplorer,
                                             .ejectAllDisks, .uninstallApp, .appDamageDiagnosis]),
                .init("Desktop & Devices", [.keepAwake, .presentationMode, .displayControl, .deadPixelTest,
                                             .mouseFixes, .cleanKeyboard, .clipboardHistory]),
                .init("System Settings", [.loginBackgroundItems, .resetPermissions, .hiddenSettings, .wifiPasswordQR])
            ]
        case .developer:
            [
                .init("Format & Convert", [.jsonFormatter, .csvJSON, .base64, .timestampConverter, .jwtDecoder]),
                .init("Inspect & Compare", [.diffChecker, .regexTester, .unicodeInspector, .cleanLinks, .coordinatePicker]),
                .init("Generate & Verify", [.hashGenerator, .uuidGenerator, .passwordGenerator, .loremIpsum])
            ]
        }
    }
}
