import AppKit
import SwiftUI
import UtilityCore

struct ToolWorkspace: View {
    let tool: Tool
    @Binding var draft: ToolDraft
    let session: WorkspaceSession
    let keepAwakeController: KeepAwakeController
    let audioRecordingController: AudioRecordingController
    let screenRecordingController: ScreenRecordingController
    let openOutput: (URL) -> Void
    let openTranscription: (URL) -> Void
    let openCaptionBurn: (URL, String) -> Void
    let openCapturedText: (CGImage, String?) -> Void
    let openAnnotation: (CGImage) -> Void
    @State private var dropTarget: Tool?
    @State private var pdfEditorReady = false
    @State private var trimReview: TrimVideoReview?
    @State private var comparison: ImageComparisonResult?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark) }

    var body: some View {
        Group {
            if tool.usesInteractiveEditor {
                interactiveEditor
            } else if draft.inputs.isEmpty, session.reports[tool] == nil,
               session.errors[tool] == nil, session.runningTool != tool {
                emptyWorkspace(for: tool)
            } else {
                editor(for: tool)
            }
        }
        .sheet(isPresented: Binding(get: { comparison != nil }, set: { if !$0 { comparison = nil } })) {
            if let comparison { ImageComparisonView(pair: comparison) }
        }
    }

    @ViewBuilder
    private var interactiveEditor: some View {
        switch tool {
        case .wordCounter: WordCounterView(draft: $draft.wordCounter)
        case .qrCode: QRToolsView(draft: $draft.qrTools)
        case .batchRename: BatchRenameView(draft: $draft.batchRename)
        case .keepAwake: KeepAwakeView(controller: keepAwakeController)
        case .jsonFormatter: JSONFormatterView(draft: $draft.jsonFormatter)
        case .base64: Base64ToolView(draft: $draft.base64)
        case .hashGenerator: HashGeneratorView(draft: $draft.hashGenerator)
        case .transcribe: TranscribeView(draft: $draft.transcribe, onCaptionHandoff: openCaptionBurn)
        case .captureText: CaptureTextView(draft: $draft.captureText, onHandoff: openCapturedText)
        case .textToSpeech: TextToSpeechView(draft: $draft.textToSpeech)
        case .recordAudio: RecordAudioView(controller: audioRecordingController, onTranscribe: openTranscription)
        case .screenshot: ScreenshotView(draft: $draft.screenshot, onAnnotate: openAnnotation)
        case .annotateScreenshot: AnnotateScreenshotView(draft: $draft.annotation)
        case .recordScreen: RecordScreenView(controller: screenRecordingController)
        case .downloadVideo: VideoDownloadView(draft: $draft.videoDownload)
        case .colorPicker: ColorPickerToolView(draft: $draft.colorPicker)
        case .markdownToPDF: MarkdownPDFView(draft: $draft.markdownPDF)
        case .addPassword, .removePassword: PDFProtectionView(tool: tool)
        default: EmptyView()
        }
    }

    private var exportSettingsIncomplete: Bool {
        switch tool {
        case .convertVideo:
            draft.options.conversion.requiresFFmpeg && draft.options.conversion.ffmpegExecutable == nil
        case .trimVideo:
            trimReview?.inputs != draft.inputs || trimReview?.options != draft.options.trim
                || trimReview?.permitsExport != true
        case .videoToGIF:
            draft.options.videoGIF.ffmpegExecutable == nil
        case .mergeVideos:
            draft.inputs.count < 2
        case .replaceAudio:
            draft.options.replaceAudio.source == nil
        case .burnSubtitles:
            draft.options.burnSubtitles.ffmpegExecutable == nil || draft.options.burnSubtitles.srt.isEmpty
        case .convertAudio:
            draft.options.audioConvert.format.requiresFFmpeg && draft.options.audioConvert.ffmpegExecutable == nil
        case .cleanUpAudio:
            draft.options.audioCleanup.executable == nil
        case .extractAudio:
            draft.options.extraction.format.requiresFFmpeg && draft.options.extraction.ffmpegExecutable == nil
        case .compressPDF:
            draft.options.pdfCompression.validationIssue != nil
        case .watermark:
            draft.options.watermark.content == .logo
                ? draft.options.watermark.logo == nil
                : draft.options.watermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .blurFaces:
            draft.inputs.contains { !draft.options.blurFaces.isReviewed($0) }
        case .redactImage:
            draft.inputs.contains { !draft.options.redactImage.hasMasks($0) }
        case .convertImages:
            draft.options.imageConversion.format.requiresImageMagick && draft.options.imageConversion.imageMagickExecutable == nil
        case .compressImages:
            draft.options.imageCompression.format.requiresImageMagick && draft.options.imageCompression.imageMagickExecutable == nil
        case .removeMetadata:
            draft.options.imageMetadata.groups.isEmpty
                || (!draft.options.imageMetadata.groups.subtracting([.location]).isEmpty
                    && draft.options.imageMetadata.exifToolExecutable == nil)
        default:
            false
        }
    }

    private func editor(for tool: Tool) -> some View {
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 15) {
                        ToolEmblem(tool: tool, palette: palette)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.title)
                                .font(.system(size: 29, weight: .semibold))
                                .tracking(-0.65)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }

                    sourceFiles(for: tool)

                    WorkspaceSection("Settings", palette: palette) {
                        switch tool {
                        case .resizeImages:
                            imageControls()
                        case .convertImages:
                            imageConversionControls()
                        case .rotateImages:
                            ImageRotateControls(inputs: draft.inputs, options: $draft.options.rotation)
                        case .beautifyScreenshot:
                            BeautifyScreenshotSettings(input: draft.inputs.first, options: $draft.options.beautify)
                        case .blurFaces:
                            BlurFacesControls(inputs: draft.inputs, options: $draft.options.blurFaces)
                        case .redactImage:
                            ImageRedactControls(inputs: draft.inputs, options: $draft.options.redactImage)
                        case .removeBackground:
                            RemoveBackgroundControls(inputs: draft.inputs, options: $draft.options.removeBackground)
                        case .watermark:
                            WatermarkControls(inputs: draft.inputs, options: $draft.options.watermark)
                        case .compressImages:
                            imageCompressionControls()
                        case .removeMetadata:
                            metadataControls()
                        case .compressVideo:
                            videoControls()
                        case .convertVideo:
                            conversionControls()
                        case .changeSpeed:
                            ChangeSpeedControls(inputs: draft.inputs, options: $draft.options.speed)
                        case .extractFrames:
                            FrameExtractionSettings(input: draft.inputs.first, options: $draft.options.frames)
                        case .trimVideo:
                            TrimVideoSettings(inputs: draft.inputs, review: $trimReview, options: $draft.options.trim)
                        case .muteVideo:
                            MuteVideoControls(inputs: draft.inputs, options: $draft.options.mute)
                        case .resizeVideo:
                            VideoResizeControls(inputs: draft.inputs, options: $draft.options.videoResize)
                        case .videoToGIF:
                            VideoGIFSettings(input: draft.inputs.first, options: $draft.options.videoGIF)
                        case .cropRotateVideo:
                            VideoCropControls(inputs: draft.inputs, options: $draft.options.crop)
                        case .mergeVideos:
                            VideoMergeControls(inputs: $draft.inputs, options: $draft.options.videoMerge)
                        case .replaceAudio:
                            ReplaceAudioControls(inputs: draft.inputs, options: $draft.options.replaceAudio)
                        case .burnSubtitles:
                            BurnSubtitlesSettings(input: draft.inputs.first, options: $draft.options.burnSubtitles, onTranscribe: openTranscription)
                        case .mediaInfo:
                            inspectionControls()
                        case .extractAudio:
                            extractionControls()
                        case .trimAudio:
                            AudioTrimControls(inputs: draft.inputs, options: $draft.options.audioTrim)
                        case .convertAudio:
                            AudioConvertControls(inputs: draft.inputs, options: $draft.options.audioConvert)
                        case .cleanUpAudio:
                            AudioCleanupControls(inputs: draft.inputs, options: $draft.options.audioCleanup)
                        case .imagesToPDF:
                            ImagesToPDFSettings(inputs: draft.inputs, options: $draft.options.imagesToPDF)
                        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages:
                            PDFEditingSettings(
                                tool: tool, input: draft.inputs.first, options: $draft.options,
                                organizerHistory: $draft.pdfOrganizerHistory, ready: $pdfEditorReady,
                                canEdit: !session.isRunning
                            )
                            .id(draft.pdfSourceRevision)
                        case .signPDF:
                            PDFSigningSettings(input: draft.inputs.first, options: $draft.options.pdfSignature,
                                               ready: $pdfEditorReady, canEdit: !session.isRunning)
                                .id(draft.pdfSourceRevision)
                        case .makePDFSearchable:
                            SearchablePDFControls(inputs: draft.inputs, options: $draft.options.searchablePDF)
                        case .compressPDF:
                            PDFCompressionControls(inputs: draft.inputs, options: $draft.options.pdfCompression)
                        case .extractText:
                            TextExtractionSettings(inputs: draft.inputs, options: $draft.options.textExtraction)
                        case .wordCounter, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo, .colorPicker, .markdownToPDF, .addPassword, .removePassword:
                            EmptyView()
                        case .mergePDFs:
                            SettingRow("Output filename") {
                                TextField("Output filename", text: Binding(
                                    get: { draft.outputName },
                                    set: { draft.outputName = $0 }
                                ))
                                .labelsHidden()
                            }
                        }
                    }
                    if let error = session.errors[tool] {
                        Label(error, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let report = session.reports[tool] {
                        WorkspaceSection("Results", palette: palette) {
                            if tool == .mediaInfo {
                                ForEach(Array(report.inspections.enumerated()), id: \.offset) { _, inspection in
                                    MediaInspectionResultView(inspection: inspection)
                                }
                            } else {
                                ForEach(Array(report.summaries.enumerated()), id: \.offset) { _, summary in
                                    Text(summary).font(.callout).textSelection(.enabled)
                                }
                            }
                            ForEach(Array(report.textExtractions.enumerated()), id: \.offset) { _, extraction in
                                TextExtractionResultView(file: extraction, password: draft.options.textExtraction.password)
                            }
                            ForEach(Array(report.metadataResults.enumerated()), id: \.offset) { _, item in
                                MetadataRemovalResultView(item: item)
                            }
                            ForEach(report.outputs, id: \.self) { output in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.accent)
                                        .accessibilityHidden(true)
                                    Text(output.lastPathComponent).lineLimit(1)
                                    Spacer()
                                    if let pair = report.imageComparisons.first(where: { $0.output == output }) {
                                        Button("Compare") { comparison = pair }
                                    }
                                    Button("Open") { openOutput(output) }
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([output])
                                    }
                                }
                            }
                            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                                Label(failure, systemImage: "exclamationmark.circle")
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(palette.canvas)
            Divider()
            HStack(spacing: 12) {
                Button {
                    chooseDestination(for: tool)
                } label: {
                    Label(draft.destination.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                .help("Choose output folder")
                .accessibilityLabel("Output folder: \(draft.destination.lastPathComponent)")
                Spacer()
                if tool == .mergePDFs {
                    Button("Preview") { session.start(tool, draft: draft, preview: true) }
                        .disabled(draft.inputs.isEmpty || session.isRunning)
                }
                Button(tool == .mediaInfo ? "Inspect media" : tool.title) { session.start(tool, draft: draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.inputs.isEmpty || session.isRunning || exportSettingsIncomplete
                              || (tool.requiresSinglePDF && !pdfEditorReady))
            }
            .controlSize(.large)
            .frame(maxWidth: 660)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(palette.surface)
        }
    }

    private func sourceFiles(for tool: Tool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.inputs.isEmpty ? "Source files" : "Source files · \(draft.inputs.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !draft.inputs.isEmpty {
                    Button(tool.requiresSinglePDF ? "Replace PDF…" : "Add files…", systemImage: tool.requiresSinglePDF ? "arrow.triangle.2.circlepath" : "plus") { chooseInputs(for: tool) }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if draft.inputs.isEmpty {
                    dropWell(for: tool)
                } else {
                    ForEach(Array(draft.inputs.enumerated()), id: \.offset) { index, input in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: tool.symbol)
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(input.lastPathComponent).lineLimit(1)
                                    if tool == .resizeImages {
                                        Text((try? ToolRunner.imagePreview(input, longestEdge: draft.pixels, options: draft.options)) ?? "Check image or sizing options")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if tool == .mergePDFs || tool == .imagesToPDF {
                                    Button("Move up", systemImage: "arrow.up") {
                                        draft.moveInputUp(at: index)
                                    }.labelStyle(.iconOnly).disabled(index == 0)
                                }
                                Button("Remove", systemImage: "minus.circle") {
                                    draft.removeInput(at: index)
                                }.labelStyle(.iconOnly)
                            }
                            if tool == .mergePDFs {
                                pageControls(input, index: index, tool: tool)
                                    .padding(.leading, 30)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < draft.inputs.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(draft.inputs.isEmpty ? palette.wash : palette.surface,
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(dropTarget == tool ? palette.accent : palette.line,
                                  style: StrokeStyle(lineWidth: 1, dash: draft.inputs.isEmpty ? [5, 4] : []))
                    .allowsHitTesting(false)
            }
            .dropDestination(for: URL.self) { urls, _ in
                addDroppedFiles(urls, to: tool)
            } isTargeted: { targeted in
                updateDropTarget(for: tool, targeted: targeted)
            }
        }
    }

    private func emptyWorkspace(for tool: Tool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(spacing: 15) {
                ToolEmblem(tool: tool, palette: palette, large: true)
                    .padding(.bottom, 6)
                Text(tool.title)
                    .font(.system(size: 36, weight: .semibold))
                    .tracking(-1.25)
                    .accessibilityAddTraits(.isHeader)
                Text(tool.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose files…") { chooseInputs(for: tool) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                Text(dropTarget == tool ? "Release to add files" : tool.dropHint)
                    .font(.callout)
                    .foregroundStyle(dropTarget == tool ? palette.accent : .secondary)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas)
        .overlay {
            if dropTarget == tool {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(palette.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            addDroppedFiles(urls, to: tool)
        } isTargeted: { targeted in
            updateDropTarget(for: tool, targeted: targeted)
        }
    }

    private func addDroppedFiles(_ urls: [URL], to tool: Tool) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        if tool.requiresSinglePDF {
            guard files.count == 1 else { return false }
            pdfEditorReady = false
            draft.replacePDF(with: files[0])
        } else {
            draft.inputs.append(contentsOf: files)
        }
        return true
    }

    private func updateDropTarget(for tool: Tool, targeted: Bool) {
        if targeted { dropTarget = tool }
        else if dropTarget == tool { dropTarget = nil }
    }

    private func dropWell(for tool: Tool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text(tool.dropTitle).font(.system(size: 14, weight: .semibold))
            Button("Choose files…") { chooseInputs(for: tool) }
                .foregroundStyle(palette.accent)
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 23)
        .background(dropTarget == tool ? palette.accent.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 16))
    }

    func option<Value>(_ path: WritableKeyPath<ToolOptions, Value>) -> Binding<Value> {
        Binding(
            get: { draft.options[keyPath: path] },
            set: { draft.options[keyPath: path] = $0 }
        )
    }

    private func pageControls(_ input: URL, index: Int, tool: Tool) -> some View {
        let range = Binding(
            get: { draft.ranges[index, default: ""] },
            set: { draft.ranges[index] = $0 }
        )
        let password = Binding(
            get: { draft.passwords[index, default: ""] },
            set: { draft.passwords[index] = $0 }
        )
        return PDFPageControls(input: input, range: range, password: password).id(input)
    }

    private func chooseInputs(for tool: Tool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = tool.inputTypes
        panel.allowsMultipleSelection = !tool.requiresSinglePDF
        if panel.runModal() == .OK {
            _ = addDroppedFiles(panel.urls, to: tool)
        }
    }

    private func chooseDestination(for tool: Tool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = draft.destination
        if panel.runModal() == .OK, let folder = panel.url {
            draft.destination = folder
        }
    }
}
