import SwiftUI
import UtilityCore

struct CSVJSONDraft {
    var input = ""
    var direction = CSVJSON.Direction.csvToJSON
    var delimiter = CSVJSON.Delimiter.comma
    var includesHeader = true
}

struct CSVJSONView: View {
    @Binding var draft: CSVJSONDraft
    @State private var revision = 0
    @State private var editorRevision = 0
    @State private var isLoading = false
    @State private var fileName: String?
    @State private var fileIssue: String?
    @State private var detectionRequest: UUID?
    @State private var delimiterMessage: String?
    @State private var saveIssue: String?
    @State private var comparison: (revision: Int, result: Result<CSVJSON.Result, Error>)?

    var body: some View {
        InteractiveToolLayout(tool: .csvJSON) { palette in
            WorkspaceSection("Convert", palette: palette) {
                Picker("Direction", selection: $draft.direction) {
                    ForEach(CSVJSON.Direction.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
                SettingRow("Delimiter") {
                    Picker("Delimiter", selection: $draft.delimiter) {
                        ForEach(CSVJSON.Delimiter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    if draft.direction != .jsonToCSV {
                        Button("Detect Delimiter", action: { detectionRequest = UUID() })
                            .disabled(draft.input.isEmpty || isLoading || detectionRequest != nil)
                        if detectionRequest != nil { ProgressView().controlSize(.small) }
                    }
                }
                if let delimiterMessage { Text(delimiterMessage).font(.callout).foregroundStyle(.secondary) }
                Toggle(draft.direction == .jsonToCSV ? "Include output header row" : "First row contains headers",
                       isOn: $draft.includesHeader)
            }
            WorkspaceSection("Input", palette: palette) {
                HStack {
                    Button("Open…", systemImage: "folder", action: open).disabled(isLoading)
                        .help("Open a UTF-8 text file")
                    if let fileName { Text(fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if isLoading { ProgressView().controlSize(.small) }
                }
                TextEditor(text: Binding(get: { draft.input }, set: {
                    draft.input = $0
                    fileIssue = nil
                    invalidate()
                }))
                .id(editorRevision)
                .font(.body.monospaced())
                .frame(minHeight: 120, maxHeight: 180)
                .disabled(isLoading)
                .accessibilityLabel(draft.direction == .jsonToCSV ? "JSON input" : "CSV input")
                if let fileIssue { Text(fileIssue).font(.callout).foregroundStyle(.secondary) }
            }
            if !draft.input.isEmpty, !isLoading {
                WorkspaceSection("Output", palette: palette) {
                    if let comparison, comparison.revision == revision {
                        switch comparison.result {
                        case .success(let result):
                            preview(result)
                        case .failure(let error):
                            Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                                .font(.callout)
                        }
                    } else {
                        ProgressView("Converting…").controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: draft.direction) { invalidate() }
        .onChange(of: draft.delimiter) { invalidate() }
        .onChange(of: draft.includesHeader) { invalidate() }
        .task(id: revision) { await convert() }
        .task(id: detectionRequest) {
            if let detectionRequest { await detectDelimiter(detectionRequest) }
        }
    }

    private func preview(_ result: CSVJSON.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(result.rows.count) rows · \(result.columns.count) columns")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(result.output) }
                Button("Export…", systemImage: "square.and.arrow.up") { export(result.output) }
            }
            if !result.columns.isEmpty {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                        GridRow { previewCells(result.columns, header: true) }
                        Divider()
                        ForEach(Array(result.rows.prefix(10).enumerated()), id: \.offset) { _, row in
                            GridRow { previewCells(row, header: false) }
                        }
                    }
                }
            }
            if result.rows.count > 10 || result.columns.count > 12 {
                Text("Showing up to 10 rows and 12 columns. Copy and export use the full output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Output text") {
                let text = result.output.prefix(4_000)
                ScrollView {
                    Text(text.isEmpty ? "Empty output" : String(text))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                if text.endIndex != result.output.endIndex {
                    Text("Showing the first 4,000 characters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let saveIssue { Text(saveIssue).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func previewCells(_ values: [String], header: Bool) -> some View {
        ForEach(Array(values.prefix(12).enumerated()), id: \.offset) { _, value in
            let prefix = value.prefix(120)
            Text(value.isEmpty ? " " : String(prefix) + (prefix.endIndex == value.endIndex ? "" : "…"))
                .font(header ? .caption.bold() : .caption.monospaced())
                .lineLimit(3)
                .frame(minWidth: 72, maxWidth: 200, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func invalidate() {
        revision += 1
        saveIssue = nil
        detectionRequest = nil
        delimiterMessage = nil
    }

    private func detectDelimiter(_ request: UUID) async {
        let input = draft.input
        let direction = draft.direction
        let originalDelimiter = draft.delimiter
        delimiterMessage = nil
        defer { if detectionRequest == request { detectionRequest = nil } }
        do {
            let worker = Task.detached(priority: .userInitiated) { try CSVJSON.detectDelimiter(input) }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, detectionRequest == request, draft.input == input,
                  draft.direction == direction, draft.delimiter == originalDelimiter else { return }
            switch result {
            case .detected(let delimiter):
                if draft.delimiter == delimiter { delimiterMessage = "\(delimiter.rawValue) is already selected." }
                else { draft.delimiter = delimiter }
            case .ambiguous(let delimiters):
                delimiterMessage = "Several separators fit: \(delimiters.map(\.rawValue).joined(separator: ", ")). Choose one."
            case .unavailable:
                delimiterMessage = "Choose a delimiter manually or enter at least two rows with matching columns."
            }
        } catch {
            if !Task.isCancelled, detectionRequest == request { delimiterMessage = error.localizedDescription }
        }
    }

    private func convert() async {
        guard !draft.input.isEmpty else { return }
        let jobRevision = revision
        let input = draft.input
        let direction = draft.direction
        let delimiter = draft.delimiter
        let includesHeader = draft.includesHeader
        do {
            try await Task.sleep(for: .milliseconds(180))
            let job = Task.detached(priority: .userInitiated) {
                try CSVJSON.convert(input, direction: direction, delimiter: delimiter, includesHeader: includesHeader)
            }
            let output = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            if !Task.isCancelled, jobRevision == revision { comparison = (jobRevision, .success(output)) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, jobRevision == revision { comparison = (jobRevision, .failure(error)) }
        }
    }

    private func open() {
        guard let url = DeveloperToolFiles.choose() else { return }
        isLoading = true
        fileIssue = nil
        detectionRequest = nil
        delimiterMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let data = try await DeveloperToolFiles.read(url)
                guard data.count <= CSVJSON.maximumInputBytes else {
                    fileIssue = "Input must be 2 MiB or smaller."
                    return
                }
                draft.input = try DeveloperToolFiles.utf8(data)
                fileName = url.lastPathComponent
                editorRevision += 1
                invalidate()
            } catch {
                fileIssue = url.lastPathComponent + " — " + error.localizedDescription
            }
        }
    }

    private func export(_ output: String) {
        do {
            try DeveloperToolFiles.save(Data(output.utf8), as: "Converted." + draft.direction.fileExtension)
            saveIssue = nil
        } catch {
            saveIssue = error.localizedDescription
        }
    }
}
