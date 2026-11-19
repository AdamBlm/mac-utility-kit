import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ToolWorkspace: View {
    let tool: Tool
    @Binding var draft: ToolDraft
    let session: WorkspaceSession
    let keepAwakeController: KeepAwakeController
    let presentationModeController: PresentationModeController
    let clipboardHistoryController: ClipboardHistoryController
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
    @State private var compressionReview: CompressionReview?
    @State private var passthroughReview: VideoPassthroughReview?
    @State private var passthroughRefreshID = UUID()
    @State private var comparison: ImageComparisonResult?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark) }

    private struct VideoPassthroughRequest: Equatable {
        let inputs: [URL]
        let options: VideoConversionOptions
        let refreshID: UUID
    }

    private struct VideoPassthroughReview {
        let request: VideoPassthroughRequest
        let failures: [(index: Int, message: String)]
    }

    private var passthroughRequest: VideoPassthroughRequest? {
        let options = draft.options.conversion
        guard tool == .convertVideo, options.mode == .passthrough, !draft.inputs.isEmpty,
              options.validationIssue == nil else { return nil }
        return .init(inputs: draft.inputs, options: options, refreshID: passthroughRefreshID)
    }

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
        .task(id: passthroughRequest) { [request = passthroughRequest] in
            guard let request else { return }
            passthroughReview = nil
            var failures: [(index: Int, message: String)] = []
            for (index, input) in request.inputs.enumerated() {
                do {
                    try await VideoConversion.checkPassthrough(input, options: request.options)
                } catch {
                    guard !Task.isCancelled else { return }
                    failures.append((index, "\(input.lastPathComponent) · \(error.localizedDescription)"))
                }
            }
            guard !Task.isCancelled else { return }
            passthroughReview = .init(request: request, failures: failures)
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
        case .presentationMode: PresentationModeView(controller: presentationModeController)
        case .jsonFormatter: JSONFormatterView(draft: $draft.jsonFormatter)
        case .base64: Base64ToolView(draft: $draft.base64)
        case .hashGenerator: HashGeneratorView(draft: $draft.hashGenerator)
        case .uuidGenerator: UUIDGeneratorView(draft: $draft.uuidGenerator)
        case .cleanLinks: CleanLinksView(draft: $draft.cleanLinks)
        case .timestampConverter: TimestampConverterView(draft: $draft.timestampConverter)
        case .loremIpsum: LoremIpsumView(draft: $draft.loremIpsum)
        case .unicodeInspector: UnicodeInspectorView(draft: $draft.unicodeInspector)
        case .diffChecker: DiffCheckerView(draft: $draft.diffChecker)
        case .regexTester: RegexTesterView(draft: $draft.regexTester)
        case .csvJSON: CSVJSONView(draft: $draft.csvJSON)
        case .coordinatePicker: CoordinatePickerView(draft: $draft.coordinatePicker)
        case .jwtDecoder: JWTDecoderView(draft: $draft.jwtDecoder)
        case .summarize: SummarizeView(draft: $draft.summarize)
        case .caseConverter: CaseConverterView(draft: $draft.caseConverter)
        case .translate: TranslateView(draft: $draft.translate)
        case .askDocument: AskDocumentView(draft: $draft.askDocument)
        case .passwordGenerator: PasswordGeneratorView()
        case .batteryHealth: BatteryHealthView()
        case .diskSpeedTest: DiskSpeedView()
        case .networkSpeedTest: NetworkSpeedTestView()
        case .storageExplorer: StorageExplorerView(draft: $draft.storageExplorer)
        case .clipboardHistory: ClipboardHistoryView(controller: clipboardHistoryController)
        case .resetPermissions: ResetPermissionsView()
        case .appDamageDiagnosis: AppDamageDiagnosisView()
        case .loginBackgroundItems: LoginBackgroundItemsView()
        case .scanDocument: DocumentScannerView(draft: $draft.scanner, stageClipboardPDF: session.stageClipboardPDF)
        case .fillFlattenForms: PDFFormsView(draft: $draft.pdfForms, stageClipboardPDF: session.stageClipboardPDF)
        case .hiddenSettings: HiddenSettingsView()
        case .cleanKeyboard: CleanKeyboardView()
        case .wifiPasswordQR: WiFiPasswordView()
        case .uninstallApp: UninstallAppView(draft: $draft.uninstallApp)
        case .displayControl: DisplayControlView(draft: $draft.displayControl)
        case .mouseFixes: MouseFixesView()
        case .organizeDownloads: OrganizeDownloadsView(draft: $draft.downloads)
        case .deadPixelTest: DeadPixelTestView()
        case .ejectAllDisks: EjectDisksView(draft: $draft.ejectDisks)
        case .zipUnzip: ArchiveToolsView(draft: $draft.archiveTools)
        case .findDuplicates: FindDuplicatesView(draft: $draft.findDuplicates)
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
        case .webPageToPDF: WebPagePDFView(draft: $draft.webPagePDF)
        case .redactPDF: RedactPDFView(draft: $draft.pdfRedaction, stageClipboardPDF: session.stageClipboardPDF)
        case .addPassword, .removePassword:
            PDFProtectionView(tool: tool, input: Binding(
                get: { draft.inputs.first },
                set: { draft.inputs = $0.map { [$0] } ?? [] }
            ), stageClipboardPDF: session.stageClipboardPDF)
        default: EmptyView()
        }
    }

    private var exportSettingsIncomplete: Bool {
        switch tool {
        case .convertVideo:
            draft.options.conversion.validationIssue != nil
                || (passthroughRequest.map { passthroughReview?.request != $0 || passthroughReview?.failures.count == $0.inputs.count } ?? false)
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
            draft.options.audioConvert.validationIssue != nil
        case .cleanUpAudio:
            draft.options.audioCleanup.executable == nil
        case .extractAudio:
            draft.options.extraction.format.requiresFFmpeg && draft.options.extraction.ffmpegExecutable == nil
        case .mergePDFs:
            draft.mergePages?.isEmpty != false || (try? PDFMergePlan.outputFilename(draft.outputName)) == nil
        case .convertDocuments:
            draft.inputs.enumerated().allSatisfy { index, input in
                DocumentConvert.exportIssue(for: input, position: index + 1, options: draft.options.documents) != nil
            }
        case .pdfToWord:
            draft.inputs.allSatisfy { PDFToWord.optionIssue($0, options: draft.options.pdfToWord) != nil }
        case .compressPDF:
            draft.options.pdfCompression.validationIssue != nil
        case .wordToPDF, .powerPointToPDF, .excelToPDF:
            tool.officePDFKind.map { kind in
                draft.inputs.allSatisfy { OfficePDF.optionIssue($0, kind: kind, options: draft.options.officePDF) != nil }
            } ?? true
        case .compressVideo:
            compressionReview?.request != .init(inputs: draft.inputs, options: draft.options)
                || compressionReview?.supportsAnyInput != true
        case .watermark:
            draft.options.watermark.content == .logo
                ? draft.options.watermark.logo == nil
                : draft.options.watermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .blurFaces:
            draft.inputs.contains { !draft.options.blurFaces.isReviewed($0) }
        case .redactImage:
            draft.inputs.contains { !draft.options.redactImage.hasMasks($0) }
        case .convertImages:
            ImageConversion.optionIssue(draft.options.imageConversion) != nil
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
                            WatermarkControls(inputs: draft.inputs, options: $draft.options.watermark,
                                              logoAttachment: $draft.watermarkLogoAttachment)
                        case .compressImages:
                            imageCompressionControls()
                            ImageCompressionPreviewControls(inputs: draft.inputs, options: draft.options.imageCompression)
                        case .removeMetadata:
                            metadataControls()
                        case .compressVideo:
                            VideoCompressionControls(inputs: draft.inputs, options: $draft.options,
                                                     advancedExpanded: $draft.showsAdvanced, review: $compressionReview,
                                                     running: session.isRunning, sample: session.sample) {
                                session.startSample(draft)
                            }
                        case .convertVideo:
                            conversionControls()
                            if let request = passthroughRequest {
                                if let review = passthroughReview, review.request == request {
                                    Button("Recheck Passthrough", systemImage: "arrow.clockwise") {
                                        passthroughRefreshID = UUID()
                                    }
                                    .disabled(session.isRunning)
                                    if !review.failures.isEmpty {
                                        Text("Compatible files can still be exported. Files listed below are checked again and skipped if they are still incompatible.")
                                            .font(.callout).foregroundStyle(.secondary)
                                        ForEach(review.failures, id: \.index) { failure in
                                            Text(failure.message).font(.caption).textSelection(.enabled)
                                        }
                                    }
                                } else {
                                    ProgressView("Checking passthrough compatibility…").controlSize(.small)
                                }
                            }
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
                        case .wordToPDF, .powerPointToPDF, .excelToPDF:
                            if let kind = tool.officePDFKind {
                                OfficePDFControls(inputs: draft.inputs, options: $draft.options.officePDF, kind: kind)
                            }
                        case .pdfToWord:
                            PDFToWordControls(inputs: draft.inputs, options: $draft.options.pdfToWord)
                        case .convertDocuments:
                            DocumentConvertControls(inputs: draft.inputs, options: $draft.options.documents)
                        case .cropPDF:
                            PDFCropControls(input: draft.inputs.first, options: $draft.options.pdfCrop,
                                            ready: $pdfEditorReady)
                                .id(draft.pdfSourceRevision)
                        case .compressPDF:
                            PDFCompressionControls(inputs: draft.inputs, options: $draft.options.pdfCompression)
                        case .extractText:
                            TextExtractionSettings(inputs: draft.inputs, options: $draft.options.textExtraction)
                        case .wordCounter, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .uuidGenerator, .cleanLinks, .timestampConverter, .loremIpsum, .unicodeInspector, .diffChecker, .regexTester, .csvJSON, .coordinatePicker, .jwtDecoder, .passwordGenerator, .batteryHealth, .diskSpeedTest, .deadPixelTest, .ejectAllDisks, .presentationMode, .networkSpeedTest, .storageExplorer, .clipboardHistory, .resetPermissions, .appDamageDiagnosis, .loginBackgroundItems, .hiddenSettings, .cleanKeyboard, .wifiPasswordQR, .uninstallApp, .displayControl, .mouseFixes, .organizeDownloads, .fillFlattenForms, .scanDocument, .findDuplicates, .zipUnzip, .summarize, .caseConverter, .translate, .askDocument, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo, .colorPicker, .markdownToPDF, .webPageToPDF, .addPassword, .removePassword, .redactPDF:
                            EmptyView()
                        case .mergePDFs:
                            PDFMergeOrderView(draft: $draft)
                            SettingRow("Output filename") {
                                TextField("Output filename", text: Binding(
                                    get: { draft.outputName },
                                    set: { draft.outputName = $0 }
                                ))
                                .labelsHidden()
                            }
                            if case .failure(let error) = Result(catching: { try PDFMergePlan.outputFilename(draft.outputName) }) {
                                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
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
                            if !report.failures.isEmpty {
                                Text("Saved \(report.outputs.count) · Issues \(report.failures.count)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
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
                            ForEach(report.videoReviews) { review in
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Export is not smaller", systemImage: "exclamationmark.circle")
                                    Text(review.summary).font(.callout).textSelection(.enabled)
                                    HStack {
                                        Button("Keep") { session.resolveVideoReview(review, keep: true) }
                                        Button("Discard") { session.resolveVideoReview(review, keep: false) }
                                    }
                                }
                            }
                            ForEach(report.outputs, id: \.self) { output in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.accent)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(output.lastPathComponent).lineLimit(1)
                                        if tool == .extractFrames {
                                            Text(output.deletingLastPathComponent().lastPathComponent)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .help(output.path)
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
                        .disabled(draft.inputs.isEmpty || session.isRunning || exportSettingsIncomplete)
                }
                Button(tool == .mediaInfo ? "Inspect media" : tool.title) {
                    let failures = passthroughReview.flatMap { $0.request == passthroughRequest ? $0.failures : nil } ?? []
                    session.start(tool, draft: draft, recheckVideoInputs: Set(failures.map(\.index)))
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.inputs.isEmpty || session.isRunning || exportSettingsIncomplete
                              || (tool.requiresSinglePDF && !pdfEditorReady)
                              || session.reports[tool]?.videoReviews.isEmpty == false)
            }
            .controlSize(.large)
            .frame(maxWidth: 660)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(palette.surface)
        }
    }

    private func resizePreview(for input: URL) -> String {
        do {
            return try ToolRunner.imagePreview(input, longestEdge: draft.pixels, options: draft.options)
        } catch {
            return error.localizedDescription
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
                    pasteFilesButton(for: tool)
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
                                        Text(resizePreview(for: input))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if tool == .mergePDFs || tool == .imagesToPDF {
                                    Button("Move up", systemImage: "arrow.up") {
                                        draft.moveInputUp(at: index)
                                    }
                                    .labelStyle(.iconOnly)
                                    .accessibilityLabel("Move \(input.lastPathComponent) up")
                                    .accessibilityHint("Source \(index + 1) of \(draft.inputs.count)")
                                    .help("Move source up")
                                    .disabled(index == 0)
                                }
                                Button("Remove", systemImage: "minus.circle") {
                                    draft.removeInput(at: index)
                                }
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("Remove \(input.lastPathComponent)")
                                .accessibilityHint("Source \(index + 1) of \(draft.inputs.count)")
                                .help("Remove source")
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
                HStack {
                    Button("Choose files…") { chooseInputs(for: tool) }
                        .buttonStyle(.borderedProminent)
                    pasteFilesButton(for: tool)
                }
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
            HStack {
                Button("Choose files…") { chooseInputs(for: tool) }
                pasteFilesButton(for: tool)
            }
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
        let inspection = Binding(
            get: { draft.mergeInspections[index] },
            set: { draft.mergeInspections[index] = $0 }
        )
        return PDFPageControls(input: input, range: range, password: password, inspection: inspection).id(input)
    }

    @ViewBuilder
    private func pasteFilesButton(for tool: Tool) -> some View {
        let acceptsPDF = tool.inputTypes.contains(.pdf)
        if acceptsPDF || tool.inputTypes.contains(where: { $0.conforms(to: .image) }) {
            let pastePDF: ((Data) throws -> Void)? = acceptsPDF ? { data in
                _ = addDroppedFiles([try session.stageClipboardPDF(data)], to: tool)
            } : nil
            if tool.inputTypes.contains(.image) {
                ClipboardFileButton(allowedTypes: tool.inputTypes, allowsMultiple: !tool.requiresSinglePDF,
                                    importsItemsIndividually: true, onPasteImage: { image in
                    let attachment = try session.stageClipboardImage(image)
                    if addDroppedFiles([attachment.url], to: tool) {
                        draft.captureAttachments.append(attachment)
                    }
                }, onPastePDF: pastePDF) { _ = addDroppedFiles($0, to: tool) }
            } else {
                ClipboardFileButton(allowedTypes: tool.inputTypes, allowsMultiple: !tool.requiresSinglePDF,
                                    importsItemsIndividually: true, onPastePDF: pastePDF) {
                    _ = addDroppedFiles($0, to: tool)
                }
            }
        }
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
