import SwiftUI
@preconcurrency import Translation
import UtilityCore

struct TranslateDraft {
    var input = ""
    var kind = TranslationDocument.Kind.text
    var source = ""
    var target = ""
    var filename: String?
}

struct TranslateView: View {
    @Binding var draft: TranslateDraft
    @State private var languages: [Locale.Language] = []
    @State private var configuration: TranslationSession.Configuration?
    @State private var pending: Job?
    @State private var completed: TranslationDocument?
    @State private var output = ""
    @State private var issue: String?
    @State private var progress: Double?
    @State private var fileTask: Task<Void, Never>?
    private var isLoadingFile: Bool { fileTask != nil }
    @State private var editorRevision = 0

    private struct Job {
        let id = UUID()
        let document: TranslationDocument
        let source: Locale.Language?
        let target: Locale.Language
    }

    var body: some View {
        InteractiveToolLayout(tool: .translate) { palette in
            WorkspaceSection("Languages", palette: palette) {
                SettingRow("From") {
                    Picker("Source language", selection: $draft.source) {
                        Text("Detect Language").tag("")
                        languageOptions
                    }
                    .labelsHidden()
                }
                SettingRow("To") {
                    Picker("Target language", selection: $draft.target) {
                        Text("Choose a language").tag("")
                        languageOptions
                    }
                    .labelsHidden()
                }
                Text("Translation runs on this Mac. Apple may ask to download language packs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(pending != nil)
            WorkspaceSection("Text", palette: palette) {
                HStack {
                    Picker("Input format", selection: $draft.kind) {
                        ForEach(TranslationDocument.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(isLoadingFile)
                    Button("Open…", systemImage: "folder", action: open)
                        .disabled(pending != nil || isLoadingFile)
                    ClipboardFileButton(allowedTypes: TranslationDocument.acceptedInputTypes,
                                        buttonOnlyTitle: "Paste File", onPasteFile: load)
                        .disabled(isLoadingFile)
                    if let name = draft.filename { Text(name).font(.caption).lineLimit(1).truncationMode(.middle).help(name) }
                    if isLoadingFile { ProgressView().controlSize(.small) }
                }
                .disabled(pending != nil)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    textEditor("Original", palette: palette, text: Binding(get: { draft.input }, set: {
                        draft.input = $0
                        draft.filename = nil
                        clear()
                    }))
                    .id(editorRevision)
                    .disabled(pending != nil || isLoadingFile)
                    textEditor("Translation", palette: palette, text: $output)
                        .disabled(completed == nil || pending != nil)
                }
                if let progress {
                    ProgressView(value: progress) { Text(progress == 0 ? "Preparing Languages…" : "Translating…") }
                        .controlSize(.small)
                }
                HStack {
                    Button("Translate", systemImage: "translate", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(pending != nil || isLoadingFile || draft.input.isEmpty || draft.target.isEmpty)
                    if pending != nil { Button("Cancel", action: cancel) }
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") { publish(copy: true) }
                        .disabled(completed == nil || output.isEmpty)
                    Button("Export…", systemImage: "square.and.arrow.up") { publish(copy: false) }
                        .disabled(completed == nil || output.isEmpty)
                }
                if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.callout) }
            }
        }
        .task {
            languages = await AppleTranslationProvider.supportedLanguages().sorted {
                displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending
            }
        }
        .translationTask(configuration) { session in
            await translate(using: session)
        }
        .onChange(of: draft.kind) { clear() }
        .onChange(of: draft.source) { clear() }
        .onChange(of: draft.target) { clear() }
        .onDisappear {
            fileTask?.cancel()
            cancel()
        }
    }

    private var languageOptions: some View {
        ForEach(languages, id: \.minimalIdentifier) { language in
            Text(displayName(language)).tag(language.minimalIdentifier)
        }
    }

    private func displayName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private func textEditor(_ name: String, palette: WorkspacePalette, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.headline)
            TextEditor(text: text)
                .font(.body.monospaced())
                .frame(minHeight: 160, idealHeight: 190, maxHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(6)
                .workspaceInset(palette)
                .accessibilityLabel(name)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clear() {
        completed = nil
        output = ""
        issue = nil
    }

    private func start() {
        guard let target = languages.first(where: { $0.minimalIdentifier == draft.target }) else { return }
        clear()
        do {
            let document = try TranslationDocument(draft.input, kind: draft.kind)
            let source = languages.first { $0.minimalIdentifier == draft.source }
            let job = Job(document: document, source: source, target: target)
            pending = job
            progress = 0
            if configuration?.source == source, configuration?.target == target {
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func translate(using session: TranslationSession) async {
        guard let job = pending else { return }
        defer {
            if pending?.id == job.id {
                pending = nil
                progress = nil
            }
        }
        do {
            let translated = try await AppleTranslationProvider.translate(
                job.document, using: session, source: job.source, target: job.target
            ) { fraction in
                await MainActor.run {
                    if pending?.id == job.id { progress = fraction }
                }
            }
            guard !Task.isCancelled, pending?.id == job.id else { return }
            output = translated
            completed = job.document
        } catch {
            if !Task.isCancelled, pending?.id == job.id { issue = error.localizedDescription }
        }
    }

    private func cancel() {
        pending = nil
        configuration = nil
        progress = nil
    }

    private func open() {
        guard let url = DeveloperToolFiles.choose(allowedTypes: TranslationDocument.acceptedInputTypes) else { return }
        load(url)
    }

    private func load(_ url: URL) {
        guard fileTask == nil, pending == nil else { return }
        issue = nil
        fileTask = Task {
            defer { fileTask = nil }
            do {
                let imported = try await TranslationDocument.load(url)
                try Task.checkCancellation()
                draft.input = imported.text
                draft.kind = imported.kind
                draft.filename = url.lastPathComponent
                editorRevision += 1
                clear()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription
            }
        }
    }

    private func publish(copy: Bool) {
        guard let completed else { return }
        do {
            let text = try completed.applyingEdits(output)
            if copy {
                DeveloperToolFiles.copy(text)
            } else {
                try DeveloperToolFiles.save(Data(text.utf8), as: "Translation." + completed.kind.fileExtension)
            }
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
