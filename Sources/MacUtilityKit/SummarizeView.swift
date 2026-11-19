import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct SummarizeDraft {
    var text = ""
    var file: URL?
    var pages = ""
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
    @Environment(\.scenePhase) private var scenePhase

    private var isPDF: Bool {
        guard let file = draft.file else { return false }
        return file.pathExtension.lowercased() == "pdf" ||
            (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
    }

    var body: some View {
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
                        Text(file.lastPathComponent).lineLimit(1).font(.callout)
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
                    .frame(minHeight: 120, maxHeight: 200)
                    .accessibilityLabel("Text to summarize")
                } else if isPDF {
                    SettingRow("Pages") {
                        TextField("All pages, or 1–3, 6", text: $draft.pages)
                    }
                    SettingRow("PDF password") {
                        SecureField("If required", text: $password)
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
                    Button("Summarize", systemImage: "text.page", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(job != nil || !availability.isAvailable || (draft.file == nil && draft.text.isEmpty))
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
        .onChange(of: draft.pages) { clearResult() }
        .onChange(of: password) { clearResult() }
        .onChange(of: draft.length) { clearResult() }
        .onChange(of: draft.format) { clearResult() }
        .onChange(of: scenePhase) { if scenePhase == .active { refreshAvailability() } }
        .onAppear(perform: refreshAvailability)
        .onDisappear(perform: cancel)
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
        clearResult()
    }

    private func start() {
        refreshAvailability()
        guard availability.isAvailable, job == nil else { return }
        clearResult()
        let source = draft.file.map { DocumentSummarizer.Source.document($0, pages: draft.pages, password: password) }
            ?? .text(draft.text)
        let request = DocumentSummarizer.Request(source: source, length: draft.length, format: draft.format)
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
                if !Task.isCancelled, jobID == id { result = summary }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, jobID == id { issue = error.localizedDescription }
            }
        }
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
