import Foundation
import Observation
import UtilityCore

struct ToolDraft {
    var inputs: [URL] = []
    var showsAdvanced = false
    var pixels = 1600
    var options = ToolOptions()
    var ranges: [Int: String] = [:]
    var passwords: [Int: String] = [:]
    var outputName = "Merged"
    var wordCounter = WordCounterDraft()
    var qrTools = QRToolsDraft()
    var batchRename = BatchRenameDraft()
    var jsonFormatter = JSONFormatterDraft()
    var base64 = Base64ToolDraft()
    var hashGenerator = HashGeneratorDraft()
    var pdfSourceRevision = UUID()
    var pdfOrganizerHistory = PDFOrganizerHistory()
    var destination = URL.downloadsDirectory

    mutating func replacePDF(with input: URL) {
        inputs = [input]
        pdfSourceRevision = UUID()
        pdfOrganizerHistory = PDFOrganizerHistory()
        options.pdfSplit.password = ""
        options.pdfOrganize = PDFOrganizeOptions()
        options.pdfDelete = PDFDeleteOptions()
        options.pdfExtract = PDFExtractOptions()
        options.pdfSignature = PDFSignatureOptions()
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
    }

    mutating func removeInput(at index: Int) {
        guard inputs.indices.contains(index) else { return }
        inputs.remove(at: index)
        ranges = afterRemoving(index, from: ranges)
        passwords = afterRemoving(index, from: passwords)
    }

    private func afterRemoving(_ index: Int, from values: [Int: String]) -> [Int: String] {
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

    var isRunning: Bool { runningTool != nil }

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

    func startAudioPreview(_ draft: ToolDraft) {
        guard !isRunning, let input = draft.inputs.first else { return }
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

    func start(_ tool: Tool, draft: ToolDraft, preview: Bool = false) {
        guard !isRunning else { return }
        runningTool = tool
        progress = 0
        previewURL = nil
        reports[tool] = nil
        errors[tool] = nil
        job = Task { @MainActor in
            defer {
                job = nil
                runningTool = nil
            }
            do {
                var options = draft.options
                options.pageRanges = draft.inputs.indices.map { draft.ranges[$0, default: ""] }
                options.pdfOutputName = draft.outputName
                options.pdfPasswords = draft.inputs.indices.map { draft.passwords[$0, default: ""] }
                let report = try await ToolRunner.run(
                    tool, inputs: draft.inputs,
                    destination: preview ? FileManager.default.temporaryDirectory : draft.destination,
                    imageSize: draft.pixels, options: options
                ) { fraction in
                    await self.updateProgress(fraction)
                }
                if preview, let output = report.outputs.first {
                    previewURL = output
                } else {
                    reports[tool] = report
                }
            } catch is CancellationError {
                errors[tool] = "Canceled."
            } catch {
                errors[tool] = error.localizedDescription
            }
        }
    }
}
