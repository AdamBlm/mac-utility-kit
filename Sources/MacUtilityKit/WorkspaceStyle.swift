import AppKit
import SwiftUI
import UtilityCore

struct WorkspacePalette {
    let dark: Bool

    var canvas: Color { dark ? Color(red: 0.095, green: 0.102, blue: 0.118) : Color(red: 0.975, green: 0.976, blue: 0.982) }
    var surface: Color { dark ? Color(red: 0.127, green: 0.136, blue: 0.158) : .white }
    var accent: Color { dark ? Color(red: 0.69, green: 0.72, blue: 1.0) : Color(red: 0.31, green: 0.32, blue: 0.68) }
    var wash: Color { accent.opacity(dark ? 0.16 : 0.075) }
    var line: Color { Color.primary.opacity(dark ? 0.12 : 0.10) }
}

struct ToolEmblem: View {
    let tool: Tool
    let palette: WorkspacePalette

    var large = false

    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: large ? 36 : 19, weight: .regular))
            .foregroundStyle(palette.accent)
            .frame(width: large ? 84 : 38, height: large ? 84 : 38)
            .background {
                RoundedRectangle(cornerRadius: large ? 23 : 11)
                    .fill(LinearGradient(
                        colors: [palette.wash, palette.accent.opacity(large ? 0.12 : 0.045)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: large ? 23 : 11)
                    .strokeBorder(palette.accent.opacity(0.12))
            }
            .accessibilityHidden(true)
    }
}

struct WorkspaceSection<Content: View>: View {
    let title: String
    let palette: WorkspacePalette
    @ViewBuilder let content: Content

    init(_ title: String, palette: WorkspacePalette, @ViewBuilder content: () -> Content) {
        self.title = title
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.line.opacity(0.65))
                    .allowsHitTesting(false)
            }
        }
    }
}

extension Tool {
    var symbol: String {
        switch self {
        case .resizeImages: "photo.on.rectangle"
        case .convertImages: "photo.badge.arrow.down"
        case .rotateImages: "rotate.right"
        case .beautifyScreenshot: "photo.artframe"
        case .blurFaces: "person.crop.rectangle"
        case .compressImages: "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: "eye.slash"
        case .mergePDFs: "document.on.document"
        case .splitPDF: "scissors"
        case .organizePDF: "square.grid.2x2"
        case .deletePDFPages: "rectangle.badge.minus"
        case .extractPDFPages: "doc.on.doc"
        case .imagesToPDF: "photo.on.rectangle.angled"
        case .pdfToImages: "photo.stack"
        case .signPDF: "signature"
        case .extractText: "text.viewfinder"
        case .wordCounter: "number"
        case .transcribe: "waveform.bubble"
        case .captureText: "viewfinder"
        case .textToSpeech: "speaker.wave.2"
        case .qrCode: "qrcode"
        case .batchRename: "rectangle.and.pencil.and.ellipsis"
        case .keepAwake: "moon.zzz"
        case .jsonFormatter: "curlybraces"
        case .base64: "arrow.left.arrow.right"
        case .hashGenerator: "number.square"
        case .changeSpeed: "speedometer"
        case .extractFrames: "rectangle.on.rectangle"
        case .trimVideo: "scissors"
        case .muteVideo: "speaker.slash"
        case .resizeVideo: "arrow.up.left.and.arrow.down.right"
        case .videoToGIF: "photo.stack"
        case .cropRotateVideo: "crop.rotate"
        case .mergeVideos: "film.stack"
        case .replaceAudio: "waveform.badge.plus"
        case .burnSubtitles: "captions.bubble"
        case .compressVideo: "film"
        case .convertVideo: "arrow.triangle.2.circlepath"
        case .mediaInfo: "info.circle"
        case .extractAudio: "waveform"
        case .trimAudio: "waveform.path"
        case .convertAudio: "arrow.triangle.2.circlepath"
        case .cleanUpAudio: "waveform.badge.minus"
        }
    }

    var subtitle: String {
        switch self {
        case .resizeImages: "Change the dimensions of one image or a whole batch."
        case .convertImages: "Change image formats and control transparency."
        case .rotateImages: "Rotate and flip images with a before-and-after preview."
        case .beautifyScreenshot: "Frame an image with a background, padding, and shadow."
        case .blurFaces: "Suggest face masks and review coverage before exporting."
        case .compressImages: "Reduce image file size and compare the result."
        case .removeMetadata: "Inspect and remove private details from image copies."
        case .mergePDFs: "Choose and combine pages from PDFs and images."
        case .splitPDF: "Save pages or page groups as separate PDFs."
        case .organizePDF: "Reorder, rotate, and remove pages from a PDF copy."
        case .deletePDFPages: "Mark the pages to remove and save a new PDF."
        case .extractPDFPages: "Save only the pages you select in a new PDF."
        case .imagesToPDF: "Arrange images and save them as a PDF."
        case .pdfToImages: "Render selected PDF pages as separate images."
        case .signPDF: "Place a visible signature on a PDF copy."
        case .extractText: "Turn text in images and PDFs into editable text."
        case .wordCounter: "Count words, characters, and reading time as you type."
        case .transcribe: "Create and edit a timestamped transcript with a local Whisper model."
        case .captureText: "Recognize text from a selected part of the screen."
        case .textToSpeech: "Listen to text with a local voice and export the audio."
        case .qrCode: "Generate and scan QR codes."
        case .batchRename: "Preview and apply filename rules in batches."
        case .keepAwake: "Keep your Mac awake for a session."
        case .jsonFormatter: "Validate, format, or minify JSON."
        case .base64: "Encode and decode text and binary files."
        case .hashGenerator: "Generate and verify local checksums."
        case .changeSpeed: "Adjust playback speed with optional pitch preservation."
        case .extractFrames: "Save selected moments from videos as images."
        case .trimVideo: "Save a selected section of a video."
        case .muteVideo: "Remove all audio or selected tracks from a video."
        case .resizeVideo: "Resize a video and preview how it fits the new frame."
        case .videoToGIF: "Turn a selected video segment into an animated GIF."
        case .cropRotateVideo: "Crop, rotate, and mirror video with a framing preview."
        case .mergeVideos: "Join video clips in the order you choose."
        case .replaceAudio: "Replace or mix the audio in a video."
        case .burnSubtitles: "Render subtitles directly onto the video."
        case .compressVideo: "Make videos smaller while keeping their resolution."
        case .convertVideo: "Save a video in another format."
        case .mediaInfo: "Inspect the streams and properties of a media file."
        case .extractAudio: "Save a selected audio track from a video."
        case .trimAudio: "Trim an audio selection, preview it on a loop, and add fades."
        case .convertAudio: "Convert audio files and choose their sample rate and channels."
        case .cleanUpAudio: "Reduce noise and hum in an audio file or video track."
        }
    }

    var dropHint: String {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata, .rotateImages, .beautifyScreenshot, .blurFaces: "or drop images anywhere in this pane"
        case .mergePDFs: "or drop PDFs and images anywhere in this pane"
        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages, .signPDF: "or drop one PDF anywhere in this pane"
        case .imagesToPDF: "or drop images anywhere in this pane"
        case .extractText: "or drop images and PDFs anywhere in this pane"
        case .wordCounter: "or drop a text file anywhere in this pane"
        case .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .transcribe, .captureText, .textToSpeech: ""
        case .compressVideo, .changeSpeed, .extractFrames, .trimVideo, .muteVideo, .resizeVideo, .videoToGIF, .cropRotateVideo, .mergeVideos, .replaceAudio, .burnSubtitles: "or drop videos anywhere in this pane"
        case .convertVideo, .extractAudio: "or drop videos anywhere in this pane"
        case .mediaInfo, .cleanUpAudio: "or drop audio or video anywhere in this pane"
        case .trimAudio, .convertAudio: "or drop audio files anywhere in this pane"
        }
    }

    var dropTitle: String {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata, .rotateImages, .beautifyScreenshot, .blurFaces: "Drop images here"
        case .mergePDFs: "Drop PDFs or images here"
        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages, .signPDF: "Drop one PDF here"
        case .imagesToPDF: "Drop images here"
        case .extractText: "Drop images or PDFs here"
        case .wordCounter: "Drop a text file here"
        case .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .transcribe, .captureText, .textToSpeech: ""
        case .compressVideo, .changeSpeed, .extractFrames, .trimVideo, .muteVideo, .resizeVideo, .videoToGIF, .cropRotateVideo, .mergeVideos, .replaceAudio, .burnSubtitles: "Drop videos here"
        case .convertVideo, .extractAudio: "Drop videos here"
        case .mediaInfo, .cleanUpAudio: "Drop media files here"
        case .trimAudio, .convertAudio: "Drop audio files here"
        }
    }
}

struct FixedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon.frame(width: 18)
            configuration.title
        }
    }
}

extension LabelStyle where Self == FixedIconLabelStyle {
    static var fixedIcon: Self { Self() }
}

struct SettingRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.callout)
                .frame(width: 110, alignment: .leading)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: 310, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

struct InteractiveToolLayout<Content: View>: View {
    let tool: Tool
    let content: (WorkspacePalette) -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(tool: Tool, @ViewBuilder content: @escaping (WorkspacePalette) -> Content) {
        self.tool = tool
        self.content = content
    }

    var body: some View {
        let palette = WorkspacePalette(dark: colorScheme == .dark)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 15) {
                    ToolEmblem(tool: tool, palette: palette)
                    Text(tool.title)
                        .font(.system(size: 29, weight: .semibold))
                        .tracking(-0.65)
                        .accessibilityAddTraits(.isHeader)
                }
                content(palette)
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(palette.canvas)
    }
}
