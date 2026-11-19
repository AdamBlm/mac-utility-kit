import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

private enum DiffViewMode: String, CaseIterable {
    case sideBySide = "Side by Side"
    case inline = "Inline"
}

struct DiffCheckerDraft {
    var original = ""
    var modified = ""
    var ignoreCase = false
    var ignoreWhitespace = false
    fileprivate var mode = DiffViewMode.sideBySide
}

struct DiffCheckerView: View {
    private enum Side: String, Hashable {
        case original = "Original"
        case modified = "Modified"

        var text: WritableKeyPath<DiffCheckerDraft, String> {
            self == .original ? \.original : \.modified
        }
    }

    @Binding var draft: DiffCheckerDraft
    @State private var revision = 0
    @State private var comparison: (revision: Int, outcome: Result<DiffChecker.Result, Error>)?
    @State private var activeChange: Int?
    @State private var loadingFiles: Set<Side> = []
    @State private var fileErrors: [Side: String] = [:]
    @State private var fileNames: [Side: String] = [:]

    var body: some View {
        InteractiveToolLayout(tool: .diffChecker) { palette in
            WorkspaceSection("Texts", palette: palette) {
                HStack(alignment: .top, spacing: 16) {
                    editor(.original)
                    editor(.modified)
                }
                HStack(spacing: 20) {
                    Toggle("Ignore whitespace", isOn: $draft.ignoreWhitespace)
                    Toggle("Ignore case", isOn: $draft.ignoreCase)
                }
            }
            if !draft.original.isEmpty || !draft.modified.isEmpty {
                WorkspaceSection("Comparison", palette: palette) {
                    if loadingFiles.isEmpty, let comparison, comparison.revision == revision {
                        switch comparison.outcome {
                        case .success(let result): resultView(result)
                        case .failure(let error): Text(error.localizedDescription).font(.callout)
                        }
                    } else {
                        ProgressView(loadingFiles.isEmpty ? "Comparing…" : "Reading File…")
                            .controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: draft.ignoreCase) { invalidate() }
        .onChange(of: draft.ignoreWhitespace) { invalidate() }
        .task(id: revision) { await compare() }
    }

    private func editor(_ side: Side) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(side.rawValue).font(.headline)
                Spacer()
                Button("Open…", systemImage: "folder") { open(side) }
                    .disabled(loadingFiles.contains(side))
                    .help("Open UTF-8 or BOM-marked UTF-16 or UTF-32")
                    .accessibilityLabel("Open \(side.rawValue.lowercased()) text file")
                ClipboardFileButton(allowedTypes: [.data], buttonOnlyTitle: "Paste \(side.rawValue) File",
                                    onPasteFile: { load($0, side) })
                    .labelStyle(.iconOnly)
                    .help("Paste a file on the \(side.rawValue.lowercased()) side")
                    .disabled(loadingFiles.contains(side))
            }
            TextEditor(text: Binding(get: { draft[keyPath: side.text] }, set: {
                draft[keyPath: side.text] = $0
                fileErrors[side] = nil
                invalidate()
            }))
            .font(.body.monospaced())
            .frame(minHeight: 108, maxHeight: 160)
            .disabled(loadingFiles.contains(side))
            .accessibilityLabel("\(side.rawValue) text")
            if let name = fileNames[side] {
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        guard !draft.original.isEmpty || !draft.modified.isEmpty else { return }
        let jobRevision = revision
        let original = draft.original
        let modified = draft.modified
        let options = DiffChecker.Options(ignoreWhitespace: draft.ignoreWhitespace, ignoreCase: draft.ignoreCase)
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
        guard !loadingFiles.contains(side) else { return }
        loadingFiles.insert(side)
        fileErrors[side] = nil
        Task {
            defer { loadingFiles.remove(side) }
            do {
                draft[keyPath: side.text] = try await DiffChecker.loadText(url)
                fileNames[side] = url.lastPathComponent
                invalidate()
            } catch {
                fileErrors[side] = url.lastPathComponent + " — " + error.localizedDescription
            }
        }
    }
}
