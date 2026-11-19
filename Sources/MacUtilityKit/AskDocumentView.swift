import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct AskDocumentDraft {
    var source: URL?
    var pages = ""
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
    @Environment(\.scenePhase) private var phase

    private struct PreviewRequest: Identifiable {
        let id = UUID()
        let index: AskDocument.Index
        let location: AskDocument.Location
        let quote: String?
    }

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
            if let issue {
                Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled)
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
                if let source = draft.source {
                    Text(source.lastPathComponent).lineLimit(1).help(source.path)
                }
            }
            .disabled(job != nil)
            if draft.index == nil {
                modelStatus
            }
            if isPDF {
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow("Pages") {
                        TextField("All pages, or a range", text: $draft.pages).textFieldStyle(.roundedBorder)
                            .onChange(of: draft.pages) { clearIndex() }
                    }
                    SettingRow("PDF password") {
                        SecureField("If required", text: $password).textFieldStyle(.roundedBorder)
                    }
                }
                .disabled(job != nil)
            }
            HStack {
                Button("Index Document", systemImage: "text.magnifyingglass", action: indexDocument)
                    .buttonStyle(.borderedProminent)
                    .disabled(job != nil || draft.source == nil)
                if let index = draft.index, let first = index.sections.first {
                    Button("Preview Document", systemImage: "doc.viewfinder") {
                        showPreview(index, location: first.location)
                    }.disabled(job != nil)
                }
                if job != nil {
                    Button("Cancel") { job?.cancel() }
                }
            }
            if let progress {
                ProgressView(value: progress.fraction) { Text(progress.message).font(.callout) }
            } else if job != nil {
                ProgressView(busyTitle).controlSize(.small)
            }
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
        let types: [UTType] = [.pdf, .plainText, .rtf, UTType(filenameExtension: "md") ?? .plainText]
        guard let source = DeveloperToolFiles.choose(allowedTypes: types) else { return }
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
        guard job == nil, let source = draft.source else { return }
        clearIndex()
        let pages = draft.pages
        let secret = password
        run("Reading document…") { id in
            let result = try await AskDocument.index(source, pages: pages, password: secret) { update in
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
