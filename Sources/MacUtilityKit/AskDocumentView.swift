import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct AskDocumentDraft {
    var source: URL?
    var pages = ""
    var recognizesMixedPDFPages = false
    var index: AskDocument.Index?
    var turns: [AskDocument.Turn] = []
    var question = ""
    var questionMode: AskDocument.QuestionMode = .automatic
}

struct AskDocumentView: View {
    @Binding var draft: AskDocumentDraft
    @State private var password = ""
    @State private var job: Task<Void, Never>?
    @State private var jobID: UUID?
    @State private var progress: AskDocument.Progress?
    @State private var busyTitle = ""
    @State private var modelReady = AppleDocumentAnswerModel.isAvailable
    @State private var modelMessage = AppleDocumentAnswerModel.message
    @State private var issue: String?
    @State private var preview: PreviewRequest?
    @State private var pdfScope: PDFScope?
    @State private var scopeRevision = UUID()
    @Environment(\.scenePhase) private var phase

    private struct PreviewRequest: Identifiable {
        let id = UUID()
        let index: AskDocument.Index
        let location: AskDocument.Location
        let quote: String?
    }

    private struct PDFScopeRequest: Equatable {
        let input: URL
        let password: String
        let revision: UUID
    }

    private struct PDFScope {
        let request: PDFScopeRequest
        let result: Result<(PDFDocument, AskDocument.PDFScopeStamp), any Error>
    }

    private var scopeRequest: PDFScopeRequest? {
        guard isPDF, let input = draft.source else { return nil }
        return PDFScopeRequest(input: input, password: password, revision: scopeRevision)
    }

    private var currentScope: Result<(PDFDocument, AskDocument.PDFScopeStamp), any Error>? {
        pdfScope?.request == scopeRequest ? pdfScope?.result : nil
    }

    private var canIndex: Bool {
        guard job == nil, draft.source != nil else { return false }
        guard isPDF else { return true }
        guard case .success(let scope) = currentScope else { return false }
        return (try? AskDocument.validatePDFScope(draft.pages, count: scope.0.pageCount)) != nil
    }

    private var documentTypes: [UTType] { [.pdf, .plainText, .rtf, UTType(filenameExtension: "md") ?? .plainText] }

    private var isPDF: Bool { draft.source.map(AskDocument.isPDF) ?? false }

    var body: some View {
        InteractiveToolLayout(tool: .askDocument) { palette in
            WorkspaceSection("Document", palette: palette) { sourceControls }
            if let index = draft.index {
                WorkspaceSection("Questions", palette: palette) { questionControls(index) }
                if !draft.turns.isEmpty {
                    WorkspaceSection("Answers", palette: palette) { turns(index) }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard job == nil, let source = urls.first, urls.count == 1, source.isFileURL,
                  let type = UTType(filenameExtension: source.pathExtension),
                  type.conforms(to: .pdf) || type.conforms(to: .plainText) || type.conforms(to: .rtf)
                    || source.pathExtension.lowercased() == "md" else { return false }
            setSource(source)
            return true
        }
        .sheet(item: $preview) { request in
            AskDocumentPreview(index: request.index, location: request.location, quote: request.quote,
                               initialPDFPassword: password)
        }
        .task(id: scopeRequest) { [request = scopeRequest] in
            guard let request else { pdfScope = nil; return }
            do {
                let scope = try await AskDocument.previewPDF(request.input, password: request.password)
                try Task.checkCancellation()
                pdfScope = PDFScope(request: request, result: .success(scope))
            } catch {
                guard !Task.isCancelled else { return }
                pdfScope = PDFScope(request: request, result: .failure(error))
            }
        }
        .onChange(of: draft.pages) { clearIndex() }
        .onChange(of: draft.recognizesMixedPDFPages) { clearIndex() }
        .onChange(of: phase) { if phase == .active { refreshModel() } }
        .onDisappear {
            job?.cancel()
            password = ""
        }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Open Document…", systemImage: "folder", action: open)
                ClipboardFileButton(allowedTypes: documentTypes, onPasteFile: setSource)
                if let source = draft.source {
                    Text(source.lastPathComponent).lineLimit(1).truncationMode(.middle).help(source.path)
                }
            }
            .disabled(job != nil)
            if draft.index == nil {
                modelStatus
            }
            if isPDF {
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow("PDF password") {
                        SecureField("If required", text: Binding(
                            get: { password },
                            set: { value in
                                password = value
                                clearIndex()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Reload Page Thumbnails", systemImage: "arrow.clockwise") {
                            scopeRevision = UUID()
                            clearIndex()
                        }
                        .labelStyle(.iconOnly)
                    }
                    switch currentScope {
                    case .success(let scope):
                        let count = scope.0.pageCount
                        PDFExportPagePicker(document: scope.0, range: $draft.pages, startsWithAll: true)
                        Toggle("Recognize text in images on every selected page", isOn: $draft.recognizesMixedPDFPages)
                        if (try? PageSelection.indices(draft.pages, pageCount: count)) != nil,
                           case .failure(let error) = Result(catching: { try AskDocument.validatePDFScope(draft.pages, count: count) }) {
                            Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                        }
                    case .failure(let error):
                        Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                    case nil:
                        ProgressView("Reading PDF pages…").controlSize(.small)
                    }
                }
                .disabled(job != nil)
            }
            HStack {
                Button("Index Document", systemImage: "text.magnifyingglass", action: indexDocument)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canIndex)
                if let index = draft.index, let first = index.sections.first {
                    Button("Preview Document", systemImage: "doc.viewfinder") {
                        showPreview(index, location: first.location)
                    }.disabled(job != nil)
                }
            }
            if draft.index == nil { jobFeedback }
            if let index = draft.index {
                Text("\(index.sections.count.formatted()) \(index.isPDF ? "pages" : "sections") indexed")
                    .font(.callout).foregroundStyle(.secondary)
                if !index.omittedPages.isEmpty {
                    Text("Unreadable or blank pages: \(index.omittedPages.map(String.init).joined(separator: ", "))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modelStatus: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(modelMessage).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !modelReady { Button("Check Again", action: refreshModel) }
        }
    }

    private func questionControls(_ index: AskDocument.Index) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            modelStatus
            if !draft.turns.isEmpty {
                Picker("Question mode", selection: $draft.questionMode) {
                    ForEach(AskDocument.QuestionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Choose New Topic to start without prior context, or Follow-up to keep it.")
                .disabled(job != nil)
            }
            HStack {
                TextField("Ask about this document", text: $draft.question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask(index) }
                Button("Ask", systemImage: "arrow.up.circle", action: { ask(index) })
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(!modelReady || job != nil)
            jobFeedback
        }
    }

    @ViewBuilder
    private var jobFeedback: some View {
        if job != nil {
            HStack {
                if let progress {
                    ProgressView(value: progress.fraction) { Text(progress.message).font(.callout) }
                } else {
                    ProgressView(busyTitle).controlSize(.small)
                }
                Button("Cancel") { job?.cancel() }
            }
        }
        if let issue {
            Label(issue, systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func turns(_ index: AskDocument.Index) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(draft.turns.reversed()) { turn in
                VStack(alignment: .leading, spacing: 8) {
                    Text(turn.question).font(.headline).textSelection(.enabled)
                    if turn.answer.hasEvidence {
                        ForEach(turn.answer.citations) { citation in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(citation.quote).textSelection(.enabled)
                                Button(citation.location.label, systemImage: "doc.text.magnifyingglass") {
                                    showPreview(index, location: citation.location, quote: citation.quote)
                                }
                                .buttonStyle(.link)
                                .accessibilityLabel("Open citation at \(citation.location.label)")
                            }
                        }
                    } else {
                        Text("Insufficient evidence in the indexed document.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if turn.id != draft.turns.first?.id { Divider() }
            }
            Button("Clear Questions") {
                draft.turns.removeAll()
                draft.questionMode = .automatic
            }
            .disabled(job != nil)
        }
    }

    private func open() {
        guard let source = DeveloperToolFiles.choose(allowedTypes: documentTypes) else { return }
        setSource(source)
    }

    private func setSource(_ url: URL) {
        draft.source = url
        draft.pages = ""
        draft.question = ""
        password = ""
        clearIndex()
    }

    private func clearIndex() {
        draft.index = nil
        draft.turns.removeAll()
        draft.questionMode = .automatic
        issue = nil
    }

    private func refreshModel() {
        modelReady = AppleDocumentAnswerModel.isAvailable
        modelMessage = AppleDocumentAnswerModel.message
    }

    private func indexDocument() {
        guard canIndex, let source = draft.source else { return }
        let reviewed = try? currentScope?.get().1
        clearIndex()
        let pages = draft.pages
        let secret = password
        let recognizesMixedPDFPages = draft.recognizesMixedPDFPages
        run("Reading document…") { id in
            let result = try await AskDocument.index(source, pages: pages, password: secret, reviewedPDF: reviewed,
                                                     recognizesMixedPDFPages: recognizesMixedPDFPages) { update in
                await MainActor.run {
                    if jobID == id { progress = update }
                }
            }
            try Task.checkCancellation()
            draft.index = result
        }
    }

    private func ask(_ index: AskDocument.Index) {
        refreshModel()
        guard modelReady, job == nil else { return }
        let question = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let history = Array(draft.turns.suffix(8))
        let mode = draft.questionMode
        run("Checking the document for evidence…") { _ in
            let answer = try await AskDocument.answer(question, in: index, history: history, mode: mode)
            try Task.checkCancellation()
            draft.turns.append(.init(question: question, answer: answer))
            if draft.turns.count > 50 { draft.turns.removeFirst() }
            draft.question = ""
            draft.questionMode = .automatic
        }
    }

    private func run(_ title: String, operation: @escaping @MainActor (UUID) async throws -> Void) {
        let id = UUID()
        jobID = id
        issue = nil
        progress = nil
        busyTitle = title
        job = Task {
            defer {
                if jobID == id {
                    jobID = nil
                    job = nil
                    progress = nil
                }
            }
            do {
                try await operation(id)
            } catch is CancellationError {
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    private func showPreview(_ index: AskDocument.Index, location: AskDocument.Location, quote: String? = nil) {
        do {
            try index.validateSource()
            preview = PreviewRequest(index: index, location: location, quote: quote)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
