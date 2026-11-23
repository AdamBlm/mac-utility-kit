import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct BatchFindReplaceDraft {
    var options = BatchFindReplaceOptions()
}

struct BatchFindReplaceView: View {
    @Binding var inputs: [URL]
    @Binding var draft: BatchFindReplaceDraft
    @State private var results: [BatchFindReplace.File] = []
    @State private var selected: Int?
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var output: URL?

    private let inputTypes = Tool.batchFindReplace.inputTypes

    var body: some View {
        InteractiveToolLayout(tool: .batchFindReplace) { palette in
            WorkspaceSection("Files", palette: palette) {
                HStack {
                    Button("Add Text Files…", systemImage: "folder", action: openFiles)
                    ClipboardFileButton(allowedTypes: inputTypes, buttonOnlyTitle: "Paste Files", onPaste: { _ = add($0) })
                }
                ForEach(Array(inputs.enumerated()), id: \.offset) { index, file in
                    HStack {
                        Text(file.lastPathComponent).lineLimit(1).help(file.path)
                        Spacer()
                        Button("Remove", systemImage: "xmark") { inputs.remove(at: index) }
                            .labelStyle(.iconOnly)
                            .help("Remove \(file.lastPathComponent)")
                    }
                }
            }
            .disabled(task != nil)
            WorkspaceSection("Replacement", palette: palette) {
                TextField("Find", text: $draft.options.pattern)
                TextField("Replace with", text: $draft.options.replacement)
                Toggle("Regular expression", isOn: $draft.options.regularExpression)
                Toggle("Ignore case", isOn: $draft.options.ignoresCase)
                if draft.options.regularExpression {
                    Text("Use $1 or ${name} for capture groups. Regex mode supports up to 262,144 UTF-16 units and 2,000 matches per file.").font(.callout).foregroundStyle(.secondary)
                }
                Button("Preview Changes", systemImage: "eye", action: preview)
                    .buttonStyle(.borderedProminent)
                    .disabled(inputs.isEmpty || draft.options.pattern.isEmpty)
            }
            .disabled(task != nil)
            if !results.isEmpty {
                WorkspaceSection("Preview", palette: palette) {
                    Picker("File", selection: $selected) {
                        ForEach(results) { file in
                            Text("\(file.id + 1). \(file.source.lastPathComponent)").tag(Optional(file.id))
                        }
                    }
                    if let file = results.first(where: { $0.id == selected }) {
                        if let error = file.error {
                            Text(error).foregroundStyle(.red)
                        } else {
                            Text("\(file.count) matches").foregroundStyle(.secondary)
                            if file.changed {
                                let sharedPrefix = zip(file.before, file.after).prefix {
                                    $0.0.utf8.elementsEqual($0.1.utf8)
                                }.count
                                let offset = max(0, sharedPrefix - 120)
                                HStack(alignment: .top) {
                                    previewText("Original", file.before, offset: offset)
                                    previewText("Replacement", file.after, offset: offset)
                                }
                            }
                        }
                    }
                    Button("Export Changed Files…", systemImage: "square.and.arrow.up", action: export)
                        .disabled(task != nil || !results.contains(where: \.changed))
                }
            }
            if task != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { task?.cancel() }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let output {
                Button("Reveal Export in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            }
        }
        .onChange(of: inputs) { clearPreview() }
        .onChange(of: draft.options) { clearPreview() }
        .onDisappear { task?.cancel() }
        .dropDestination(for: URL.self) { urls, _ in
            task == nil && add(urls)
        }
    }

    private func previewText(_ label: String, _ text: String, offset: Int) -> some View {
        let remaining = text.dropFirst(offset)
        return VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text((offset > 0 ? "…" : "") + String(remaining.prefix(4_000))
                     + (remaining.dropFirst(4_000).isEmpty ? "" : "…"))
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = inputTypes
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { _ = add(panel.urls) }
    }

    private func add(_ urls: [URL]) -> Bool {
        var files = inputs
        for url in urls where !files.contains(url) && LocalInputFile.matches(url, allowedTypes: inputTypes) {
            files.append(url)
        }
        guard files.count > inputs.count else { return false }
        guard files.count <= BatchFindReplace.maximumFiles else {
            error = "Choose up to \(BatchFindReplace.maximumFiles) text files."
            return false
        }
        inputs = files
        return true
    }

    private func clearPreview() {
        task?.cancel()
        results = []
        selected = nil
        error = nil
        output = nil
    }

    private func preview() {
        let files = inputs
        let options = draft.options
        clearPreview()
        run {
            let preview = try await BatchFindReplace.preview(files, options: options)
            try Task.checkCancellation()
            guard inputs == files, draft.options == options else { return }
            results = preview
            selected = (preview.first(where: \.changed) ?? preview.first)?.id
        }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let preview = results
        run { output = try await BatchFindReplace.export(preview, to: destination) }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        error = nil
        task = Task {
            defer { task = nil }
            do { try await operation() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
