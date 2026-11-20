import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

private enum DiffViewMode: String, CaseIterable {
    case sideBySide = "Side by Side"
    case inline = "Inline"
}

struct DiffCheckerDraft {
    fileprivate struct Source {
        var text = ""
        var url: URL?
    }
    fileprivate var original = Source()
    fileprivate var modified = Source()
    var ignoreCase = false
    var ignoreWhitespace = false
    var ignoreBlankLines = false
    fileprivate var mode = DiffViewMode.sideBySide
}

struct DiffCheckerView: View {
    private enum Side: String, Hashable {
        case original = "Original"
        case modified = "Modified"

        var source: WritableKeyPath<DiffCheckerDraft, DiffCheckerDraft.Source> {
            self == .original ? \.original : \.modified
        }
    }

    @Binding var draft: DiffCheckerDraft
    @State private var revision = 0
    @State private var comparison: (revision: Int, outcome: Result<DiffChecker.Result, Error>)?
    @State private var activeChange: Int?
    @State private var fileTasks: [Side: Task<Void, Never>] = [:]
    @State private var fileErrors: [Side: String] = [:]
    private var hasInput: Bool {
        !draft.original.text.isEmpty || !draft.modified.text.isEmpty || draft.original.url != nil || draft.modified.url != nil
    }

    var body: some View {
        InteractiveToolLayout(tool: .diffChecker) { palette in
            WorkspaceSection("Texts", palette: palette) {
                HStack(alignment: .top, spacing: 16) {
                    editor(.original)
                    editor(.modified)
                }
                Button("Swap Sides", systemImage: "arrow.left.arrow.right") {
                    let original = draft.original
                    draft.original = draft.modified
                    draft.modified = original
                    fileErrors.removeAll()
                    invalidate()
                }
                .disabled(!hasInput || !fileTasks.isEmpty)
                HStack(spacing: 20) {
                    Toggle("Ignore whitespace", isOn: $draft.ignoreWhitespace)
                    Toggle("Ignore blank lines", isOn: $draft.ignoreBlankLines)
                    Toggle("Ignore case", isOn: $draft.ignoreCase)
                }
            }
            if hasInput {
                WorkspaceSection("Comparison", palette: palette) {
                    if fileTasks.isEmpty, let comparison, comparison.revision == revision {
                        switch comparison.outcome {
                        case .success(let result): resultView(result)
                        case .failure(let error): Text(error.localizedDescription).font(.callout)
                        }
                    } else {
                        ProgressView(fileTasks.isEmpty ? "Comparing…" : "Reading File…")
                            .controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: draft.ignoreCase) { invalidate() }
        .onChange(of: draft.ignoreWhitespace) { invalidate() }
        .onChange(of: draft.ignoreBlankLines) { invalidate() }
        .onDisappear { for task in fileTasks.values { task.cancel() } }
        .task(id: revision) { await compare() }
    }

    private func editor(_ side: Side) -> some View {
        let isLoading = fileTasks[side] != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(side.rawValue).font(.headline)
                Spacer()
                Button("Open…", systemImage: "folder") { open(side) }
                    .disabled(isLoading)
                    .help("Open UTF-8 or BOM-marked UTF-16 or UTF-32")
                    .accessibilityLabel("Open \(side.rawValue.lowercased()) text file")
                ClipboardFileButton(allowedTypes: [.data], buttonOnlyTitle: "Paste \(side.rawValue) File",
                                    onPasteFile: { load($0, side) })
                    .labelStyle(.iconOnly)
                    .help("Paste a file on the \(side.rawValue.lowercased()) side")
                    .disabled(isLoading)
            }
            TextEditor(text: Binding(get: { draft[keyPath: side.source].text }, set: {
                draft[keyPath: side.source] = .init(text: $0)
                fileErrors[side] = nil
                invalidate()
            }))
            .font(.body.monospaced())
            .frame(minHeight: 108, maxHeight: 160)
            .disabled(isLoading)
            .accessibilityLabel("\(side.rawValue) text")
            if let url = draft[keyPath: side.source].url {
                HStack {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(url.path)
                    Button("Reload \(side.rawValue) File", systemImage: "arrow.clockwise") { load(url, side) }
                        .labelStyle(.iconOnly)
                        .disabled(isLoading)
                }
            }
            if let issue = fileErrors[side] {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resultView(_ result: DiffChecker.Result) -> some View {
        if result.changeStarts.isEmpty {
            Label("No differences", systemImage: "checkmark.circle").font(.callout)
        } else {
            if result.usedCoarseAlignment {
                Text("The files differ substantially. The unmatched lines are shown as one block.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollViewReader { scroll in
                HStack {
                    Picker("Layout", selection: $draft.mode) {
                        ForEach(DiffViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    Spacer()
                    Button("Previous change", systemImage: "chevron.up") {
                        navigate(-1, result, scroll)
                    }
                    .labelStyle(.iconOnly)
                    .disabled((activeChange ?? 0) <= 0)
                    Text(activeChange.map { "\($0 + 1) of \(result.changeStarts.count)" }
                         ?? "\(result.changeStarts.count) changes")
                        .font(.callout.monospacedDigit())
                    Button("Next change", systemImage: "chevron.down") {
                        navigate(1, result, scroll)
                    }
                    .labelStyle(.iconOnly)
                    .disabled((activeChange ?? -1) >= result.changeStarts.count - 1)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(result.rows.indices, id: \.self) { index in
                            diffRow(result.rows[index])
                                .id(index)
                        }
                    }
                }
                .frame(maxHeight: 460)
                .onChange(of: draft.mode) {
                    if let activeChange, result.changeStarts.indices.contains(activeChange) {
                        scroll.scrollTo(result.changeStarts[activeChange], anchor: .top)
                    }
                }
            }
        }
    }

    private func navigate(_ delta: Int, _ result: DiffChecker.Result, _ scroll: ScrollViewProxy) {
        let index = (activeChange ?? -1) + delta
        guard result.changeStarts.indices.contains(index) else { return }
        activeChange = index
        scroll.scrollTo(result.changeStarts[index], anchor: .top)
    }

    @ViewBuilder
    private func diffRow(_ row: DiffChecker.Row) -> some View {
        switch draft.mode {
        case .sideBySide:
            HStack(alignment: .top, spacing: 2) {
                line(row.original, side: .original, changed: row.changed)
                line(row.modified, side: .modified, changed: row.changed)
            }
        case .inline:
            if row.changed {
                if row.original != nil { line(row.original, side: .original, changed: true) }
                if row.modified != nil { line(row.modified, side: .modified, changed: true) }
            } else {
                line(row.modified, side: .modified, changed: false)
            }
        }
    }

    private func line(_ line: DiffChecker.Line?, side: Side, changed: Bool) -> some View {
        let tint: Color = side == .original ? .red : .green
        return HStack(alignment: .top, spacing: 7) {
            Text(line.map { String($0.number) } ?? "")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
            Text(changed && line != nil ? (side == .original ? "−" : "+") : " ")
                .foregroundStyle(.secondary)
                .accessibilityLabel(changed && line != nil ? (side == .original ? "Removed" : "Added") : "")
            if let line {
                Text(highlighted(line, tint: tint)).textSelection(.enabled)
            }
        }
        .font(.callout.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .background(changed && line != nil ? tint.opacity(0.12) : .clear)
    }

    private func highlighted(_ line: DiffChecker.Line, tint: Color) -> AttributedString {
        guard !line.segments.isEmpty else { return AttributedString(line.text) }
        var text = AttributedString()
        for segment in line.segments {
            var part = AttributedString(segment.text)
            if segment.changed { part.backgroundColor = tint.opacity(0.28) }
            text += part
        }
        return text
    }

    private func invalidate() {
        revision += 1
        activeChange = nil
    }

    private func compare() async {
        guard hasInput else { return }
        let jobRevision = revision
        let original = draft.original.text
        let modified = draft.modified.text
        let options = DiffChecker.Options(ignoreWhitespace: draft.ignoreWhitespace, ignoreCase: draft.ignoreCase,
                                          ignoreBlankLines: draft.ignoreBlankLines)
        do {
            try await Task.sleep(for: .milliseconds(180))
            let job = Task.detached(priority: .userInitiated) {
                try DiffChecker.compare(original, modified, options: options)
            }
            let result = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            if !Task.isCancelled, jobRevision == revision { comparison = (jobRevision, .success(result)) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, jobRevision == revision { comparison = (jobRevision, .failure(error)) }
        }
    }

    private func open(_ side: Side) {
        guard let url = DeveloperToolFiles.choose() else { return }
        load(url, side)
    }

    private func load(_ url: URL, _ side: Side) {
        guard fileTasks[side] == nil else { return }
        fileErrors[side] = nil
        fileTasks[side] = Task {
            defer { fileTasks[side] = nil }
            do {
                let text = try await DiffChecker.loadText(url)
                try Task.checkCancellation()
                draft[keyPath: side.source] = .init(text: text, url: url)
                invalidate()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    fileErrors[side] = url.lastPathComponent + " — " + error.localizedDescription
                }
            }
        }
    }
}
