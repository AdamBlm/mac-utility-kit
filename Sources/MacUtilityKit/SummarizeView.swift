import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct SummarizeDraft {
    var text = ""
    var file: URL?
    var pages = ""
    var recognizesMixedPDFPages = false
    var length = DocumentSummarizer.Length.brief
    var format = DocumentSummarizer.Format.paragraph
}

struct SummarizeView: View {
    @Binding var draft: SummarizeDraft
    @State private var availability = AppleSystemSummarizer.availability
    @State private var password = ""
    @State private var result: DocumentSummarizer.Result?
    @State private var issue: String?
    @State private var progress: DocumentSummarizer.Progress?
    @State private var job: Task<Void, Never>?
    @State private var jobID: UUID?
    @State private var pagePreview: PagePreview?
    @State private var previewRevision = 0
    @Environment(\.scenePhase) private var scenePhase

    private struct PreviewRequest: Equatable, Sendable {
        let file: URL
        let password: String
        let revision: Int
    }

    private struct PreviewDocument {
        let document: PDFDocument
        let stamp: PDFSourceStamp
    }

    private struct PagePreview {
        let request: PreviewRequest
        let result: Result<PreviewDocument, any Error>
    }

    private var isPDF: Bool {
        guard let file = draft.file else { return false }
        return file.pathExtension.lowercased() == "pdf" ||
            (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
    }

    var body: some View {
        let request = isPDF ? draft.file.map { PreviewRequest(file: $0, password: password, revision: previewRevision) } : nil
        let preview = pagePreview?.request == request ? pagePreview?.result : nil
        let loaded = try? preview?.get()
        let selection = loaded.map { pdf in
            Result { try DocumentSummarizer.validatePDFSelection(draft.pages, pageCount: pdf.document.pageCount) }
        }
        InteractiveToolLayout(tool: .summarize) { palette in
            WorkspaceSection("On-Device Model", palette: palette) {
                HStack {
                    Label(availability.message,
                          systemImage: availability.isAvailable ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.callout)
                    Spacer(minLength: 12)
                    if !availability.isAvailable {
                        Button("Check Again", systemImage: "arrow.clockwise", action: refreshAvailability)
                    }
                }
            }
            WorkspaceSection("Source", palette: palette) {
                HStack {
                    Button("Open…", systemImage: "folder", action: open)
                    ClipboardFileButton(allowedTypes: Tool.summarize.inputTypes, onPasteFile: { setSource($0) })
                    if let file = draft.file {
                        Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle).font(.callout).help(file.path)
                        Button("Use Pasted Text", systemImage: "text.alignleft") {
                            setSource(nil)
                        }
                    }
                }
                if draft.file == nil {
                    TextEditor(text: Binding(get: { draft.text }, set: {
                        draft.text = $0
                        clearResult()
                    }))
                    .font(.body.monospaced())
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .workspaceInset(palette)
                    .accessibilityLabel("Text to summarize")
                } else if isPDF {
                    SettingRow("PDF password") {
                        SecureField("If required", text: $password)
                    }
                    if let loaded {
                        PDFExportPagePicker(document: loaded.document, range: $draft.pages, startsWithAll: true)
                        Toggle("Recognize text in images on every selected page", isOn: $draft.recognizesMixedPDFPages)
                        if case .failure(let error) = selection,
                           (try? PageSelection.indices(draft.pages, pageCount: loaded.document.pageCount)) != nil {
                            Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                        }
                    } else if case .failure(let error) = preview {
                        Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView("Reading PDF pages…").controlSize(.small)
                    }
                }
            }
            .disabled(job != nil)
            WorkspaceSection("Summary", palette: palette) {
                SettingRow("Length") {
                    Picker("Summary length", selection: $draft.length) {
                        ForEach(DocumentSummarizer.Length.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(job != nil)
                }
                SettingRow("Format") {
                    Picker("Summary format", selection: $draft.format) {
                        ForEach(DocumentSummarizer.Format.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(job != nil)
                }
                HStack {
                    Button("Summarize", systemImage: "text.page") { start(reviewedPDF: loaded?.stamp) }
                        .buttonStyle(.borderedProminent)
                        .disabled(job != nil || !availability.isAvailable || (draft.file == nil && draft.text.isEmpty) ||
                                  (request != nil && (try? selection?.get()) == nil))
                    if job != nil { Button("Cancel", action: cancel) }
                }
                if let progress {
                    ProgressView(value: progress.fraction) { Text(progress.message).font(.callout) }
                }
                if let issue {
                    Label(issue, systemImage: "exclamationmark.circle").font(.callout)
                }
            }
            if let result {
                WorkspaceSection("Result", palette: palette) {
                    if !result.omittedPages.isEmpty {
                        Label("No readable text on pages \(result.omittedPages.map(String.init).joined(separator: ", ")).",
                              systemImage: "exclamationmark.circle")
                            .font(.callout)
                    }
                    Text(result.summary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(result.summary) }
                        Button("Export…", systemImage: "square.and.arrow.up") { export(result.summary) }
                    }
                }
            }
        }
        .task(id: request) {
            guard let request else { pagePreview = nil; return }
            if pagePreview?.request != request { pagePreview = nil }
            do {
                let pdf = try await Self.loadPDF(request)
                guard !Task.isCancelled else { return }
                pagePreview = PagePreview(request: request, result: .success(pdf))
            } catch {
                guard !Task.isCancelled else { return }
                pagePreview = PagePreview(request: request, result: .failure(error))
            }
        }
        .onChange(of: draft.pages) { clearResult() }
        .onChange(of: draft.recognizesMixedPDFPages) { clearResult() }
        .onChange(of: password) { clearResult() }
        .onChange(of: draft.length) { clearResult() }
        .onChange(of: draft.format) { clearResult() }
        .onChange(of: scenePhase) { if scenePhase == .active { refreshAvailability() } }
        .onAppear(perform: refreshAvailability)
        .onDisappear(perform: cancel)
    }

    @concurrent
    private static func loadPDF(_ request: PreviewRequest) async throws -> sending PreviewDocument {
        try Task.checkCancellation()
        let stamp = try PDFSourceStamp.read(request.file)
        let pdf = try TextExtraction.openPDF(stamp.resolved, password: request.password)
        guard try PDFSourceStamp.read(request.file) == stamp else {
            throw ToolError.invalid("The PDF changed while opening. Reopen it to review the current pages.")
        }
        try Task.checkCancellation()
        return PreviewDocument(document: pdf, stamp: stamp)
    }

    private func refreshAvailability() {
        availability = AppleSystemSummarizer.availability
    }

    private func clearResult() {
        result = nil
        issue = nil
    }

    private func open() {
        guard let file = DeveloperToolFiles.choose(allowedTypes: Tool.summarize.inputTypes) else { return }
        setSource(file)
    }

    private func setSource(_ file: URL?) {
        draft.file = file
        draft.pages = ""
        password = ""
        previewRevision += 1
        clearResult()
    }

    private func start(reviewedPDF: PDFSourceStamp?) {
        refreshAvailability()
        guard availability.isAvailable, job == nil else { return }
        clearResult()
        let file = draft.file
        guard verifyReviewedPDF(reviewedPDF, file: file) else { return }
        let source = draft.file.map { DocumentSummarizer.Source.document($0, pages: draft.pages, password: password) }
            ?? .text(draft.text)
        let request = DocumentSummarizer.Request(source: source, length: draft.length, format: draft.format,
                                                 recognizesMixedPDFPages: draft.recognizesMixedPDFPages)
        let id = UUID()
        jobID = id
        job = Task {
            defer {
                if jobID == id {
                    jobID = nil
                    job = nil
                    progress = nil
                }
            }
            do {
                let jobProgress: @Sendable (DocumentSummarizer.Progress) async -> Void = { update in
                    await MainActor.run {
                        if jobID == id { progress = update }
                    }
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try await DocumentSummarizer.summarize(request, progress: jobProgress)
                }
                let summary = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if !Task.isCancelled, jobID == id, verifyReviewedPDF(reviewedPDF, file: file) { result = summary }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, jobID == id { issue = error.localizedDescription }
            }
        }
    }

    private func verifyReviewedPDF(_ expected: PDFSourceStamp?, file: URL?) -> Bool {
        guard let expected, let file else { return true }
        guard (try? PDFSourceStamp.read(file)) != expected else { return true }
        previewRevision += 1
        issue = "The PDF changed. Review the refreshed pages before summarizing."
        return false
    }

    private func cancel() {
        jobID = nil
        job?.cancel()
        job = nil
        progress = nil
    }

    private func export(_ text: String) {
        do {
            try DeveloperToolFiles.save(Data(text.utf8), as: "Summary.txt")
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
