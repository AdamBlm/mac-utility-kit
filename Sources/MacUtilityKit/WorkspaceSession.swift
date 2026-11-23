import CoreGraphics
import Foundation
import Observation
import UtilityCore

struct ToolDraft {
    var inputs: [URL] = []
    var showsAdvanced = false
    var pixels = 1600
    var options: ToolOptions = {
        var options = ToolOptions()
        options.audioConvert = .recommended
        return options
    }()
    var ranges: [Int: String] = [:]
    var passwords: [Int: String] = [:]
    var mergeInspections: [Int: PDFMergeInspection] = [:]
    var mergeOrder: [PDFMergePageReference]?
    var mergeSourceRevision = UUID()
    var outputName = "Merged"
    var wordCounter = WordCounterDraft()
    var qrTools = QRToolsDraft()
    var batchRename = BatchRenameDraft()
    var jsonFormatter = JSONFormatterDraft()
    var base64 = Base64ToolDraft()
    var hashGenerator = HashGeneratorDraft()
    var uuidGenerator = UUIDGeneratorDraft()
    var cleanLinks = CleanLinksDraft()
    var timestampConverter = TimestampConverterDraft()
    var loremIpsum = LoremIpsumDraft()
    var unicodeInspector = UnicodeInspectorDraft()
    var diffChecker = DiffCheckerDraft()
    var regexTester = RegexTesterDraft()
    var csvJSON = CSVJSONDraft()
    var coordinatePicker = CoordinatePickerDraft()
    var jwtDecoder = JWTDecoderDraft()
    var summarize = SummarizeDraft()
    var batchFindReplace = BatchFindReplaceDraft()
    var caseConverter = CaseConverterDraft()
    var translate = TranslateDraft()
    var askDocument = AskDocumentDraft()
    var scanner = DocumentScannerDraft()
    var pdfForms = PDFFormsDraft()
    var ejectDisks = EjectDisksDraft()
    var findDuplicates = FindDuplicatesDraft()
    var storageExplorer = StorageExplorerDraft()
    var downloads = OrganizeDownloadsDraft()
    var uninstallApp = UninstallAppDraft()
    var displayControl = DisplayControlDraft()
    var archiveTools = ArchiveToolsDraft()
    var transcribe = TranscribeDraft()
    var captureText = CaptureTextDraft()
    var textToSpeech = TextToSpeechDraft()
    var screenshot = ScreenshotDraft()
    var annotation = AnnotateScreenshotDraft()
    var videoDownload = VideoDownloadDraft()
    var colorPicker = ColorPickerToolDraft()
    var markdownPDF = MarkdownPDFDraft()
    var webPagePDF = WebPagePDFDraft()
    var pdfRedaction = PDFRedactionDraft()
    var captureAttachments: [CaptureTextAttachment] = []
    var watermarkLogoAttachment: CaptureTextAttachment?
    var pdfSourceRevision = UUID()
    var pdfOrganizerHistory = PDFOrganizerHistory()
    var destination = URL.downloadsDirectory

    mutating func addInputs(_ urls: [URL], for tool: Tool) -> Bool {
        let files = urls.filter { LocalInputFile.matches($0, allowedTypes: tool.inputTypes) }
        guard !files.isEmpty else { return false }
        if tool.requiresSinglePDF {
            guard files.count == 1 else { return false }
            replacePDF(with: files[0])
        } else {
            inputs.append(contentsOf: files)
        }
        return true
    }

    mutating func replacePDF(with input: URL) {
        inputs = [input]
        pdfSourceRevision = UUID()
        pdfOrganizerHistory = PDFOrganizerHistory()
        options.pdfSplit.password = ""
        options.pdfOrganize = PDFOrganizeOptions()
        options.pdfDelete = PDFDeleteOptions()
        options.pdfExtract = PDFExtractOptions()
        options.pdfSignature = PDFSignatureOptions()
        options.pdfCrop = PDFCropOptions()
        options.pdfToImages.password = ""
        options.pdfToImages.range = ""
    }

    mutating func moveInputUp(at index: Int) {
        guard inputs.indices.contains(index), index > 0 else { return }
        inputs.swapAt(index, index - 1)
        let range = ranges[index]
        ranges[index] = ranges[index - 1]
        ranges[index - 1] = range
        let password = passwords[index]
        passwords[index] = passwords[index - 1]
        passwords[index - 1] = password
        mergeSourceRevision = UUID()
        let inspection = mergeInspections[index]
        mergeInspections[index] = mergeInspections[index - 1]
        mergeInspections[index - 1] = inspection
        mergeOrder = mergeOrder?.map { page in
            let source = page.source == index ? index - 1 : (page.source == index - 1 ? index : page.source)
            return PDFMergePageReference(source: source, page: page.page)
        }
    }

    mutating func removeInput(at index: Int) {
        guard inputs.indices.contains(index) else { return }
        let removed = inputs.remove(at: index)
        if !inputs.contains(removed) { captureAttachments.removeAll { $0.url == removed } }
        ranges = afterRemoving(index, from: ranges)
        passwords = afterRemoving(index, from: passwords)
        mergeSourceRevision = UUID()
        mergeInspections = afterRemoving(index, from: mergeInspections)
        mergeOrder = mergeOrder?.compactMap { page in
            guard page.source != index else { return nil }
            return PDFMergePageReference(source: page.source > index ? page.source - 1 : page.source, page: page.page)
        }
    }

    var mergePages: [PDFMergePageReference]? {
        let selectedRanges = inputs.indices.map { ranges[$0, default: ""] }
        var counts: [Int] = []
        for (index, input) in inputs.enumerated() {
            if selectedRanges[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" {
                counts.append(0)
            } else if let inspection = mergeInspections[index], inspection.input == input,
                      let count = inspection.count(password: passwords[index, default: ""]) {
                counts.append(count)
            } else {
                return nil
            }
        }
        guard let selected = try? PDFMergePlan.selectedPages(counts: counts, ranges: selectedRanges) else { return nil }
        return PDFMergePlan.reconcile(selected: selected, custom: mergeOrder)
    }

    private func afterRemoving<T>(_ index: Int, from values: [Int: T]) -> [Int: T] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            key == index ? nil : (key > index ? key - 1 : key, value)
        })
    }
}

@MainActor
@Observable
final class WorkspaceSession {
    var drafts: [Tool: ToolDraft] = [:]
    private(set) var runningTool: Tool?
    private(set) var progress = 0.0
    private(set) var previewURL: URL?
    private(set) var sample: VideoSample?
    private(set) var reports: [Tool: JobReport] = [:]
    private(set) var errors: [Tool: String] = [:]
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var temporaryPDFDirectory: WorkspacePDFDirectory?
    @ObservationIgnored private var nextPastedImageNumber = 1

    init() {
        let retention = DraftRetention.shared
        if let text = retention.retained(for: .wordCounter) {
            drafts[.wordCounter, default: ToolDraft()].wordCounter.text = text
        }
        if let text = retention.retained(for: .caseConverter) {
            drafts[.caseConverter, default: ToolDraft()].caseConverter.input = text
        }
    }

    var isRunning: Bool { runningTool != nil }

    func loadFinderAction(_ action: FinderFileAction, with tool: Tool) -> Bool {
        guard action.supports(tool) else { return false }
        var draft = ToolDraft()
        guard draft.addInputs(action.files, for: tool) else { return false }
        drafts[tool] = draft
        reports[tool] = nil
        errors[tool] = nil
        return true
    }

    func setDraft(_ updated: ToolDraft, for tool: Tool) {
        let previous = drafts.updateValue(updated, forKey: tool)
        let changedText: String?
        switch tool {
        case .wordCounter:
            changedText = previous?.wordCounter.text.utf8.elementsEqual(updated.wordCounter.text.utf8) == true
                ? nil : updated.wordCounter.text
        case .caseConverter:
            changedText = previous?.caseConverter.input.utf8.elementsEqual(updated.caseConverter.input.utf8) == true
                ? nil : updated.caseConverter.input
        default:
            changedText = nil
        }
        if let changedText { DraftRetention.shared.record(changedText, for: tool) }
    }

    func cancel() { job?.cancel() }

    private func updateProgress(_ fraction: Double) {
        progress = max(progress, fraction)
    }

    func startSample(_ draft: ToolDraft) {
        guard !isRunning, let input = draft.inputs.first else { return }
        runningTool = .compressVideo
        progress = 0
        sample = nil
        errors[.compressVideo] = nil
        job = Task { @MainActor in
            defer {
                runningTool = nil
                job = nil
            }
            do {
                sample = try await ToolRunner.sampleVideo(input, destination: draft.destination, options: draft.options)
            } catch is CancellationError {
                errors[.compressVideo] = "Canceled."
            } catch {
                errors[.compressVideo] = error.localizedDescription
            }
        }
    }

    func startAudioPreview(_ draft: ToolDraft, input: URL) {
        guard !isRunning, draft.inputs.contains(input) else { return }
        runningTool = .extractAudio
        progress = 0
        previewURL = nil
        errors[.extractAudio] = nil
        job = Task { @MainActor in
            defer {
                runningTool = nil
                job = nil
            }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacUtilityKit-Audio-" + UUID().uuidString, isDirectory: true)
            let output = folder.appendingPathComponent("Preview.m4a")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try await AudioExtraction.preview(input, to: output, options: draft.options.extraction)
                try Task.checkCancellation()
                previewURL = output
            } catch {
                try? FileManager.default.removeItem(at: folder)
                errors[.extractAudio] = error is CancellationError ? "Canceled." : error.localizedDescription
            }
        }
    }

    private func mergeStamps(_ draft: ToolDraft, plan: [PDFMergePageReference]) -> [Int: PDFMergeSourceStamp] {
        Dictionary(uniqueKeysWithValues: Set(plan.map(\.source)).compactMap { index in
            draft.mergeInspections[index]?.stamp.map { (index, $0) }
        })
    }

    func resolveVideoReview(_ review: VideoCompressionReview, keep: Bool) {
        guard var report = reports[.compressVideo], report.videoReviews.contains(where: { $0.id == review.id }) else {
            return
        }
        do {
            if keep {
                report.outputs.append(try review.keep())
                report.summaries.append(review.summary)
            } else {
                try review.discard()
            }
            report.videoReviews.removeAll { $0.id == review.id }
            reports[.compressVideo] = report
            errors[.compressVideo] = nil
        } catch {
            errors[.compressVideo] = error.localizedDescription
        }
    }

    func stageClipboardPDF(_ data: Data) throws -> URL {
        try pdfDirectory().stageClipboardPDF(data)
    }

    func stageClipboardImage(_ image: CGImage) throws -> CaptureTextAttachment {
        let attachment = try CaptureTextAttachment(image: image, filename: "Pasted Image \(nextPastedImageNumber).png")
        nextPastedImageNumber += 1
        return attachment
    }

    private func pdfDirectory() throws -> WorkspacePDFDirectory {
        let directory = try temporaryPDFDirectory ?? WorkspacePDFDirectory()
        temporaryPDFDirectory = directory
        return directory
    }

    func openCapturedText(_ attachment: CaptureTextAttachment, language: String?) throws {
        guard runningTool != .extractText else {
            throw ToolError.invalid("Wait for the current text extraction to finish.")
        }
        var draft = drafts[.extractText, default: ToolDraft()]
        draft.inputs = [attachment.url]
        draft.captureAttachments = [attachment]
        draft.options.textExtraction.language = language
        draft.options.textExtraction.range = ""
        draft.options.textExtraction.region = nil
        draft.options.textExtraction.password = ""
        drafts[.extractText] = draft
        reports[.extractText] = nil
        errors[.extractText] = nil
    }

    func start(_ tool: Tool, draft: ToolDraft, preview: Bool = false, recheckVideoInputs: Set<Int> = []) {
        guard !isRunning, reports[tool]?.videoReviews.isEmpty != false else { return }
        runningTool = tool
        progress = 0
        previewURL = nil
        reports[tool] = nil
        errors[tool] = nil
        let center = ExportActivityCenter.shared
        let export = preview ? nil : center.start(tool) { [weak self] in self?.cancel() }
        job = Task { @MainActor in
            defer {
                withExtendedLifetime(draft.watermarkLogoAttachment) {}
                if let export { center.finish(export) }
                job = nil
                runningTool = nil
            }
            do {
                var options = draft.options
                options.videoPassthroughRecheck = recheckVideoInputs
                options.reviewLargerVideos = tool == .compressVideo && !preview
                options.pageRanges = draft.inputs.indices.map { draft.ranges[$0, default: ""] }
                options.pdfOutputName = draft.outputName
                options.pdfPasswords = draft.inputs.indices.map { draft.passwords[$0, default: ""] }
                if tool == .mergePDFs {
                    guard let plan = draft.mergePages, !plan.isEmpty else {
                        throw ToolError.invalid("Check the source pages and choose at least one page to merge.")
                    }
                    options.pdfMergeOrder = plan
                    options.pdfMergeSourceStamps = mergeStamps(draft, plan: plan)
                }
                let managed: ManagedVideoEngines?
                if tool == .mediaInfo, options.inspection.ffprobeExecutable == nil {
                    let engines = VideoEngineSettings.shared
                    if engines.installed == nil { await engines.refresh() }
                    managed = engines.installed
                    options.inspection.automaticFFprobeExecutable =
                        managed?.ffprobe ?? HomebrewVideoTools.ffmpegPair()?.ffprobe
                } else {
                    managed = nil
                }
                defer { withExtendedLifetime(managed) {} }
                let destination = preview ? try pdfDirectory().url : draft.destination
                let report = try await ToolRunner.run(
                    tool, inputs: draft.inputs,
                    destination: destination,
                    imageSize: draft.pixels, options: options
                ) { fraction in
                    await self.updateProgress(fraction)
                    if let export { await center.update(export, fraction: fraction) }
                }
                if preview, let output = report.outputs.first {
                    previewURL = output
                } else {
                    reports[tool] = report
                    if export != nil { center.postCompletion(tool, report: report) }
                }
            } catch is CancellationError {
                errors[tool] = "Canceled."
            } catch {
                errors[tool] = error.localizedDescription
            }
        }
    }
}
