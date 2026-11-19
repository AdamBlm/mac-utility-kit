import AppKit
import QuickLook
import SwiftUI
import UtilityCore

struct FindDuplicatesDraft {
    var folders: [URL] = []
    var options = DuplicateScanOptions()
    var report: DuplicateScanResult?
    var selected: Set<URL> = []
    var actionIssues: [DuplicateIssue] = []
    var resultMessage: String?
    var trashInProgress = false
}

struct FindDuplicatesView: View {
    @Binding var draft: FindDuplicatesDraft
    @State private var scanTask: Task<Void, Never>?
    @State private var trashTask: Task<Void, Never>?
    @State private var progress: DuplicateScanProgress?
    @State private var confirmation = false
    @State private var preview: URL?
    @State private var error: String?
    @State private var pathFilter = ""

    private var busy: Bool { scanTask != nil || draft.trashInProgress }

    var body: some View {
        InteractiveToolLayout(tool: .findDuplicates) { palette in
            WorkspaceSection("Folders", palette: palette) { folders }
            if let report = draft.report {
                WorkspaceSection("Duplicates", palette: palette) { results(report) }
                let issues = report.issues + draft.actionIssues
                if !issues.isEmpty {
                    WorkspaceSection("Files requiring attention", palette: palette) { issuesView(issues) }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            if let result = draft.resultMessage { Text(result).font(.callout).foregroundStyle(.secondary) }
        }
        .dropDestination(for: URL.self) { urls, _ in addFolders(urls) }
        .quickLookPreview($preview)
        .onDisappear { scanTask?.cancel() }
        .confirmationDialog("Move the selected copies to Trash?", isPresented: $confirmation, titleVisibility: .visible) {
            Button("Move \(draft.selected.count) to Trash", role: .destructive, action: moveToTrash)
        } message: {
            Text("Files are checked again before moving. At least one verified copy stays in each group.")
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Add Folders…", systemImage: "folder.badge.plus", action: chooseFolders)
                .disabled(busy)
            ForEach(draft.folders, id: \.self) { folder in
                HStack {
                    Text(folder.path).lineLimit(1).truncationMode(.middle)
                        .help(folder.path)
                    Spacer()
                    Button("Remove \(folder.lastPathComponent)", systemImage: "xmark") {
                        draft.folders.removeAll { $0 == folder }
                        clearResults()
                    }
                    .labelStyle(.iconOnly).disabled(busy)
                }
            }
            Toggle("Scan subfolders", isOn: $draft.options.includesSubfolders)
                .disabled(busy).onChange(of: draft.options.includesSubfolders) { clearResults() }
            Toggle("Include hidden files", isOn: $draft.options.includesHiddenFiles)
                .disabled(busy).onChange(of: draft.options.includesHiddenFiles) { clearResults() }
            SettingRow("Minimum file size") {
                Picker("Minimum file size", selection: $draft.options.minimumFileBytes) {
                    Text("Any size").tag(Int64(0))
                    ForEach([1_000_000, 10_000_000, 100_000_000, 1_000_000_000] as [Int64], id: \.self) { size in
                        Text(bytes(size)).tag(size)
                    }
                }
                .labelsHidden()
                .disabled(busy)
                .onChange(of: draft.options.minimumFileBytes) { clearResults() }
            }
            Text("Symbolic links and package subfolders are skipped.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Scan for Duplicates", systemImage: "magnifyingglass", action: scan)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || draft.folders.isEmpty)
                if let progress, scanTask != nil {
                    switch progress {
                    case .enumerating(let count):
                        ProgressView("Scanning \(count.formatted()) files…").controlSize(.small)
                    case .matching(let completed, let total):
                        ProgressView(value: Double(completed), total: Double(max(1, total)))
                            .frame(maxWidth: 140).accessibilityLabel("Comparing file contents")
                    case .verifying:
                        ProgressView("Verifying exact matches…").controlSize(.small)
                    }
                    Button("Cancel") { scanTask?.cancel() }
                }
            }
        }
    }

    private func results(_ report: DuplicateScanResult) -> some View {
        let visible = report.groups(matchingPath: pathFilter)
        let selectedHidden = hiddenSelectionCount(in: visible)
        return LazyVStack(alignment: .leading, spacing: 14) {
            if report.groups.isEmpty {
                Text("No exact duplicates in \(report.fileCount.formatted()) scanned files.")
                    .foregroundStyle(.secondary)
            } else {
                SettingRow("Filter") {
                    TextField("File name or folder path", text: $pathFilter)
                        .accessibilityLabel("Filter duplicate groups by path")
                        .disabled(busy)
                    if !pathFilter.isEmpty {
                        Button("Clear Filter", systemImage: "xmark.circle") { pathFilter = "" }
                            .labelStyle(.iconOnly).disabled(busy)
                    }
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(visible.count == report.groups.count
                             ? "\(report.groups.count.formatted()) duplicate groups"
                             : "\(visible.count.formatted()) of \(report.groups.count.formatted()) duplicate groups")
                            .font(.callout.weight(.semibold))
                        Text("Estimated reclaimable after emptying Trash · \(bytes(reclaimable(report)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Move to Trash…", systemImage: "trash") { confirmation = true }
                        .disabled(draft.selected.isEmpty || selectedHidden > 0 || busy)
                    if draft.trashInProgress {
                        ProgressView().controlSize(.small)
                        if trashTask != nil { Button("Stop") { trashTask?.cancel() } }
                    }
                }
                if selectedHidden > 0 {
                    Text("\(selectedHidden.formatted()) selected files are hidden. Clear the filter to review them before moving to Trash.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if visible.isEmpty {
                    Text("No duplicate groups match this path.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(visible) { group in
                    Divider()
                    LazyVStack(alignment: .leading, spacing: 7) {
                        Text("\(group.files.count) copies · \(bytes(group.fileSize)) each")
                            .font(.callout.weight(.medium))
                        let kept = group.files.filter { !draft.selected.contains($0.url) }.count
                        ForEach(group.files) { file in fileRow(file, kept: kept) }
                    }
                }
            }
        }
    }

    private func fileRow(_ file: DuplicateFile, kept: Int) -> some View {
        let selected = draft.selected.contains(file.url)
        return HStack(spacing: 10) {
            Toggle("Select \(file.url.lastPathComponent) for Trash", isOn: Binding(
                get: { draft.selected.contains(file.url) }, set: { enabled in
                    if enabled && kept > 1 { draft.selected.insert(file.url) }
                    else if !enabled { draft.selected.remove(file.url) }
                }
            ))
            .labelsHidden()
            .disabled(busy || (!selected && kept == 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(file.url.path)
                Text(file.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(selected ? "Trash" : "Keep").font(.caption).foregroundStyle(.secondary)
            Button("Preview \(file.url.lastPathComponent)", systemImage: "eye") { preview = file.url }
                .labelStyle(.iconOnly)
                .disabled(draft.trashInProgress)
        }
    }

    private func issuesView(_ issues: [DuplicateIssue]) -> some View {
        DisclosureGroup("\(issues.count.formatted()) issues") {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.url.path).lineLimit(1).truncationMode(.middle).help(issue.url.path)
                    Text(issue.message).foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 4)
            }
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        _ = addFolders(panel.urls)
    }

    private func addFolders(_ urls: [URL]) -> Bool {
        guard !busy else { return false }
        let folders = urls.filter { url in
            url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        var changed = false
        for folder in folders where !draft.folders.contains(folder) {
            draft.folders.append(folder)
            changed = true
        }
        if changed { clearResults() }
        return changed
    }

    private func clearResults() {
        pathFilter = ""
        draft.report = nil
        draft.selected = []
        draft.actionIssues = []
        draft.resultMessage = nil
        error = nil
    }

    private func scan() {
        clearResults()
        let roots = draft.folders
        let options = draft.options
        progress = .enumerating(files: 0)
        scanTask = Task {
            defer { scanTask = nil; progress = nil }
            do {
                let result = try await FindDuplicates.scan(roots, options: options) { update in
                    await MainActor.run { progress = update }
                }
                if !Task.isCancelled { draft.report = result }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func hiddenSelectionCount(in visible: [DuplicateGroup]) -> Int {
        guard !draft.selected.isEmpty else { return 0 }
        return draft.selected.count - visible.reduce(0) { count, group in
            count + group.files.count { draft.selected.contains($0.url) }
        }
    }

    private func moveToTrash() {
        guard let report = draft.report, !busy, !draft.selected.isEmpty,
              hiddenSelectionCount(in: report.groups(matchingPath: pathFilter)) == 0 else { return }
        let selected = draft.selected
        preview = nil
        error = nil
        draft.actionIssues = []
        draft.resultMessage = nil
        draft.trashInProgress = true
        trashTask = Task {
            defer {
                trashTask = nil
                draft.trashInProgress = false
            }
            do {
                let result = try await FindDuplicates.trash(selected, from: report)
                draft.report = report.removing(result.moved)
                draft.selected.subtract(result.moved)
                draft.actionIssues = result.failures
                let message = "Moved \(result.moved.count) file\(result.moved.count == 1 ? "" : "s") to Trash."
                draft.resultMessage = result.wasCancelled ? "Stopped. \(message)" : message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func reclaimable(_ report: DuplicateScanResult) -> Int64 {
        report.groups.flatMap(\.files)
            .filter { draft.selected.contains($0.url) }
            .reduce(0) { total, file in
                let sum = total.addingReportingOverflow(file.estimatedReclaimableBytes)
                return sum.overflow ? Int64.max : sum.partialValue
            }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
