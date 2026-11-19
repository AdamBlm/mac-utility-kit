import AppKit
import SwiftUI
import UtilityCore

struct StorageExplorerDraft {
    var folder: URL?
    var report: StorageScanReport?
    var reportID = UUID()
    var directory = 0
    var selected: Set<Int> = []
    var isTrashing = false
    var trashResult: StorageTrashResult?
}

struct StorageExplorerView: View {
    @Binding var draft: StorageExplorerDraft
    @State private var activity = Activity()
    @State private var scanTask: Task<Void, Never>?
    @State private var error: String?
    @State private var queryResults: BrowserResult?
    @State private var maximumRows = 150
    @State private var threshold = SizeFilter.all
    @State private var customMinimum = "250"
    @State private var measurement = StorageExplorer.Measurement.allocated
    @State private var confirmsTrash = false

    @MainActor @Observable
    fileprivate final class Activity {
        var progress: StorageScanProgress?
        func update(_ progress: StorageScanProgress) { self.progress = progress }
    }

    private enum SizeFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "Folder contents"
        case ten = "Files ≥ 10 MB"
        case hundred = "Files ≥ 100 MB"
        case thousand = "Files ≥ 1 GB"
        case custom = "Custom Minimum"
        var id: Self { self }
        var minimum: Int64? {
            switch self {
            case .all, .custom: nil
            case .ten: 10_000_000
            case .hundred: 100_000_000
            case .thousand: 1_000_000_000
            }
        }
    }

    private struct BrowserQuery: Equatable, Sendable {
        let reportID: UUID
        let directory: Int
        let threshold: SizeFilter
        let minimum: Int64?
        let measurement: StorageExplorer.Measurement

        var isValid: Bool { threshold != .custom || minimum != nil }
    }

    private struct BrowserResult {
        let query: BrowserQuery
        let ids: [Int]
    }

    private var busy: Bool { scanTask != nil || draft.isTrashing }

    private var query: BrowserQuery {
        let minimum = threshold == .custom ? StorageExplorer.minimumBytes(megabytes: customMinimum) : threshold.minimum
        return BrowserQuery(reportID: draft.reportID, directory: draft.directory, threshold: threshold,
                            minimum: minimum, measurement: measurement)
    }

    var body: some View {
        InteractiveToolLayout(tool: .storageExplorer) { palette in
            WorkspaceSection("Location", palette: palette) { scanControls }
            if let report = draft.report {
                WorkspaceSection("Usage", palette: palette) { browse(report) }
                if !report.issues.isEmpty {
                    WorkspaceSection("Scan issues", palette: palette) { scanIssues(report) }
                }
            }
            if let result = draft.trashResult {
                WorkspaceSection("Trash results", palette: palette) { trashResult(result) }
            }
        }
        .onDisappear { scanTask?.cancel() }
        .task(id: query) {
            guard let report = draft.report else { return }
            let request = query
            guard request.isValid, let ids = await Self.browserItems(in: report, query: request) else { return }
            guard !Task.isCancelled, request == query else { return }
            queryResults = BrowserResult(query: request, ids: ids)
            maximumRows = 150
        }
        .confirmationDialog("Move selected items to Trash?", isPresented: $confirmsTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive, action: trash)
        } message: {
            if let report = draft.report {
                let preview = StorageExplorer.trashPreview(draft.selected, in: report)
                let names = preview.items.prefix(4).map {
                    StorageExplorer.displayedPath(for: $0, under: report.root)
                }.joined(separator: "\n")
                let additional = max(0, preview.items.count - 4)
                let label = additional == 0 ? names : names + "\nand \(additional) more"
                Text("\(label)\nEstimated space after emptying Trash: \(format(preview.estimatedBytes)).")
            }
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose Folder or Volume…", systemImage: "folder", action: chooseFolder)
                Button("Scan", systemImage: "chart.bar.xaxis", action: scan)
                    .buttonStyle(.borderedProminent).disabled(draft.folder == nil)
            }
            .disabled(busy)
            if let folder = draft.folder {
                Text(folder.path).font(.callout).lineLimit(1).truncationMode(.middle).help(folder.path)
            }
            if scanTask != nil {
                HStack {
                    ProgressView("Scanning \(activity.progress?.itemCount.formatted() ?? "0") items…")
                        .controlSize(.small)
                    Button("Cancel") { scanTask?.cancel() }
                }
                if let current = activity.progress?.current {
                    Text(current.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if draft.isTrashing {
                ProgressView("Rechecking and moving selected items…").controlSize(.small)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func browse(_ report: StorageScanReport) -> some View {
        let current = report.items[draft.directory]
        let ids = queryResults?.query == query ? queryResults?.ids : nil
        let bytes = measurement.bytes(current)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Go Up", systemImage: "chevron.up") {
                    if let parent = current.parent { draft.directory = parent }
                }.disabled(current.parent == nil)
                Text(current.name).font(.headline).lineLimit(1).help(current.url.path)
                Spacer()
                Text((current.isPartial ? "At least " : "") + format(bytes))
                    .font(.headline).monospacedDigit()
            }
            HStack {
                Picker("Measurement", selection: $measurement) {
                    ForEach(StorageExplorer.Measurement.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
                Spacer()
                Picker("Show", selection: $threshold) {
                    ForEach(SizeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if threshold == .custom {
                SettingRow("Minimum size") {
                    TextField("250", text: $customMinimum)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 95)
                        .accessibilityLabel("Minimum file size in megabytes")
                    Text("MB").foregroundStyle(.secondary)
                }
            }
            Text("On-disk sizes are estimates. Hard-linked data counts once; shared APFS clone blocks can overlap.")
                .font(.caption).foregroundStyle(.secondary)
            if !query.isValid {
                Text("Enter a valid positive whole number of megabytes.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let ids {
                if ids.isEmpty {
                    Text("No matching items.").font(.callout).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(ids.prefix(maximumRows), id: \.self) { id in
                        let item = report.items[id]
                        let name = threshold == .all ? item.name : StorageExplorer.displayedPath(for: item, under: current)
                        itemRow(item, name: name, parentBytes: bytes)
                    }
                }
                if ids.count > maximumRows {
                    Button("Show More (\((ids.count - maximumRows).formatted()) remaining)") { maximumRows += 150 }
                }
            } else {
                ProgressView("Sorting…").controlSize(.small)
            }
            Divider()
            HStack {
                if !draft.selected.isEmpty {
                    let preview = StorageExplorer.trashPreview(draft.selected, in: report)
                    Text("\(preview.items.count) selected · \(format(preview.estimatedBytes)) estimated")
                        .lineLimit(1)
                    Button("Clear") { draft.selected.removeAll() }
                }
                Spacer()
                Button("Move Selected to Trash…", systemImage: "trash") {
                    confirmsTrash = true
                }.disabled(draft.selected.isEmpty)
            }
            .font(.callout)
        }
        .disabled(busy)
    }

    private func itemRow(_ item: StorageScanItem, name: String, parentBytes: Int64) -> some View {
        HStack(spacing: 9) {
            Toggle(isOn: Binding(get: { draft.selected.contains(item.id) }, set: { checked in
                if checked { draft.selected.insert(item.id) } else { draft.selected.remove(item.id) }
            })) { EmptyView() }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Select \(name)")
                .disabled(!item.canTrash)
            if item.kind == .folder {
                Button {
                    draft.directory = item.id
                    threshold = .all
                } label: {
                    Label(name, systemImage: "folder").lineLimit(1)
                }
                .buttonStyle(.plain).help(item.url.path)
            } else {
                Label(name, systemImage: item.kind == .link ? "link" : "doc")
                    .lineLimit(1).truncationMode(.middle).help(item.url.path)
            }
            if item.isPartial {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary).help("This item was only partially measured.")
            }
            Spacer()
            if item.isHardLink {
                Image(systemName: "link").foregroundStyle(.secondary)
                    .help("A shared hard link. Only one path is counted and this path is excluded from the reclaim estimate.")
            }
            ProgressView(value: fraction(measurement.bytes(item), of: parentBytes))
                .frame(width: 40).accessibilityHidden(true)
            Text(format(measurement.bytes(item))).monospacedDigit().foregroundStyle(.secondary)
            Button("Reveal \(name) in Finder", systemImage: "arrow.up.right.square") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }.labelStyle(.iconOnly)
        }
        .font(.callout)
    }

    private func scanIssues(_ report: StorageScanReport) -> some View {
        DisclosureGroup("\(report.issues.count + report.omittedIssueCount) locations skipped or incomplete") {
            issueRows(report.issues)
            if report.omittedIssueCount > 0 {
                Text("\(report.omittedIssueCount) additional issues").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func trashResult(_ result: StorageTrashResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(result.moved.count) item\(result.moved.count == 1 ? "" : "s") moved to Trash.")
            issueRows(result.issues)
        }
        .font(.callout)
    }

    private func issueRows(_ issues: [StorageScanIssue]) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.url.path).lineLimit(1).truncationMode(.middle).help(issue.url.path)
                    Text(issue.reason).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let folder = panel.url {
            draft.folder = folder
            draft.report = nil
            draft.selected.removeAll()
            draft.trashResult = nil
            scan()
        }
    }

    private func scan() {
        guard !busy, let folder = draft.folder else { return }
        let current = draft.report?.items[draft.directory].url
        error = nil
        let scanActivity = activity
        scanActivity.progress = nil
        scanTask = Task {
            defer { scanTask = nil }
            do {
                let report = try await StorageExplorer.scan(folder) { progress in await scanActivity.update(progress) }
                try Task.checkCancellation()
                apply(report, retaining: current)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(_ report: StorageScanReport, retaining current: URL?) {
        draft.report = report
        draft.directory = report.items.first(where: { $0.url == current && $0.kind == .folder })?.id ?? 0
        draft.selected.removeAll()
        draft.reportID = UUID()
    }

    private func trash() {
        guard !busy, let report = draft.report, let folder = draft.folder else { return }
        let selected = draft.selected
        let current = report.items[draft.directory].url
        draft.isTrashing = true
        error = nil
        Task {
            defer { draft.isTrashing = false }
            draft.trashResult = await StorageExplorer.trash(selected, in: report)
            draft.report = nil
            draft.selected.removeAll()
            do {
                apply(try await StorageExplorer.scan(folder), retaining: current)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private nonisolated static func browserItems(in report: StorageScanReport, query: BrowserQuery) async -> [Int]? {
        try? StorageExplorer.browserItems(in: report, directory: query.directory, minimumBytes: query.minimum,
                                          measurement: query.measurement)
    }

    private func fraction(_ bytes: Int64, of total: Int64) -> Double {
        total > 0 ? min(1, Double(bytes) / Double(total)) : 0
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
