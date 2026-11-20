import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ArchiveToolsDraft {
    enum Mode: String, CaseIterable, Identifiable {
        case create = "Create ZIP"
        case extract = "Extract"

        var id: Self { self }
    }

    var mode = Mode.create
    var inputs: [URL] = []
    var archive: URL?
    var destination: URL?
    var conflicts = ArchiveConflictPolicy.rename
    var busy = false
}

struct ArchiveToolsView: View {
    @Binding var draft: ArchiveToolsDraft
    @State private var password = ""
    @State private var protectsZIP = false
    @State private var listing: ArchiveListing?
    private var entries: [ArchiveEntry]? { listing?.entries }
    @State private var selection: Set<ArchiveEntry.ID> = []
    @State private var filter = ""
    @State private var entryOrder = ArchiveEntryOrder.archive
    @State private var listingRevision = UUID()
    @State private var browsedRows: BrowsedEntries?
    @State private var task: Task<Void, Never>?
    @State private var operation = ""
    @State private var error: String?
    @State private var result: String?

    private struct EntryRequest: Equatable, Sendable {
        let revision: UUID
        let order: ArchiveEntryOrder
        let filter: String
    }

    private struct BrowsedEntries: Sendable {
        let request: EntryRequest
        let rows: [ArchiveEntry]
        let ids: Set<ArchiveEntry.ID>
    }

    private var request: EntryRequest {
        EntryRequest(revision: listingRevision, order: entryOrder, filter: filter.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canExtractSelection: Bool {
        guard !selection.isEmpty else { return false }
        if request.filter.isEmpty { return true }
        guard let browsedRows, browsedRows.request == request else { return false }
        return selection.isSubset(of: browsedRows.ids)
    }

    var body: some View {
        InteractiveToolLayout(tool: .zipUnzip) { palette in
            Picker("Archive operation", selection: $draft.mode) {
                ForEach(ArchiveToolsDraft.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(draft.busy)
            switch draft.mode {
            case .create:
                WorkspaceSection("Files and folders", palette: palette) { createControls }
            case .extract:
                WorkspaceSection("Archive", palette: palette) { archiveControls }
                if let entries {
                    WorkspaceSection("Contents", palette: palette) { contents(entries) }
                    WorkspaceSection("Destination", palette: palette) { destinationControls }
                }
            }
            operationStatus
        }
        .dropDestination(for: URL.self) { urls, _ in chooseInputs(urls) }
        .onChange(of: draft.mode) {
            password = ""
            protectsZIP = false
            error = nil
            result = nil
        }
        .onDisappear {
            task?.cancel()
            password = ""
        }
    }

    private var createControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Add Files or Folders…", systemImage: "plus", action: browseInputs)
            ForEach(draft.inputs, id: \.self) { url in
                HStack {
                    Text(url.lastPathComponent).lineLimit(1).help(url.path)
                    Spacer()
                    Button("Remove \(url.lastPathComponent)", systemImage: "xmark") {
                        draft.inputs.removeAll { $0 == url }
                    }
                    .labelStyle(.iconOnly)
                }
            }
            Toggle("Protect with a password", isOn: $protectsZIP)
            if protectsZIP {
                SettingRow("Password") {
                    SecureField("Required", text: $password).textFieldStyle(.roundedBorder)
                }
                Text("Uses AES-256. Open with an archive app that supports encrypted ZIPs.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Create ZIP…", systemImage: "archivebox", action: create)
                .buttonStyle(.borderedProminent)
                .disabled(draft.inputs.isEmpty || (protectsZIP && password.isEmpty))
        }
        .disabled(draft.busy)
    }

    private var archiveControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose Archive…", systemImage: "archivebox", action: browseInputs)
                if let archive = draft.archive {
                    Text(archive.lastPathComponent).lineLimit(1).help(archive.path)
                }
            }
            Text("ZIP, RAR, 7z and TAR")
                .font(.callout).foregroundStyle(.secondary)
            SettingRow("Password") {
                SecureField("If required", text: $password).textFieldStyle(.roundedBorder)
            }
            Button("Read Contents", systemImage: "list.bullet.rectangle", action: readContents)
                .disabled(draft.archive == nil)
        }
        .disabled(draft.busy)
    }

    private func contents(_ entries: [ArchiveEntry]) -> some View {
        let request = self.request
        let isUnfiltered = request.order == .archive && request.filter.isEmpty
        let current = browsedRows?.request == request ? browsedRows : nil
        let visible = isUnfiltered ? entries : current?.rows
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(selection.count.formatted()) of \(entries.count.formatted()) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                if request.filter.isEmpty {
                    Button("Select All") { selection = Set(entries.map(\.id)) }.disabled(entries.isEmpty)
                } else {
                    Button("Select Matches") {
                        if let current { selection = ArchiveEntryOrder.extractionSelection(for: current.ids, in: entries) }
                    }
                    .disabled(current?.ids.isEmpty != false)
                }
                Button("Clear Selection") { selection.removeAll() }.disabled(selection.isEmpty)
            }
            .font(.callout)
            if !request.filter.isEmpty, current != nil, !selection.isEmpty, !canExtractSelection {
                Text("Some selected entries are hidden. Select Matches or clear the search before extracting.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !entries.isEmpty {
                HStack {
                    TextField("Find an entry", text: $filter).textFieldStyle(.roundedBorder)
                    Picker("Sort by", selection: $entryOrder) {
                        ForEach(ArchiveEntryOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .fixedSize()
                }
            }
            if let visible, visible.isEmpty {
                Text(request.filter.isEmpty ? "This archive has no files or folders." : "No matching entries.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if visible == nil {
                ProgressView("Preparing entries…").controlSize(.small)
            }
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(visible ?? []) { entry in
                    Toggle(isOn: Binding(get: { selection.contains(entry.id) }, set: { select(entry, on: $0, entries: entries) })) {
                        HStack {
                            Label(entry.path, systemImage: entry.isDirectory ? "folder" : "doc")
                                .lineLimit(1).truncationMode(.middle).help(entry.path)
                            Spacer()
                            if entry.isEncrypted {
                                Image(systemName: "lock").accessibilityLabel("Encrypted")
                            }
                            if !entry.isDirectory, let bytes = entry.uncompressedSize, bytes >= 0 {
                                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .task(id: request) {
            guard !isUnfiltered, let result = await Self.rows(entries, for: request), !Task.isCancelled else { return }
            browsedRows = result
        }
        .disabled(draft.busy)
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose Folder…", systemImage: "folder", action: chooseDestination)
                if let destination = draft.destination {
                    Text(destination.path).lineLimit(1).truncationMode(.middle).help(destination.path)
                }
            }
            SettingRow("If a top-level item exists") {
                Picker("Archive name conflict", selection: $draft.conflicts) {
                    ForEach(ArchiveConflictPolicy.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            Button("Extract Selected", systemImage: "arrow.down.to.line", action: extract)
                .buttonStyle(.borderedProminent)
                .disabled(draft.destination == nil || !canExtractSelection)
        }
        .disabled(draft.busy)
    }

    @ViewBuilder
    private var operationStatus: some View {
        if draft.busy {
            HStack {
                ProgressView(operation).controlSize(.small)
                Button("Cancel") { task?.cancel() }.disabled(task?.isCancelled != false)
            }
        }
        if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        if let result { Text(result).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
    }

    private func browseInputs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = draft.mode == .create
        panel.allowsMultipleSelection = draft.mode == .create
        if panel.runModal() == .OK { _ = chooseInputs(panel.urls) }
    }

    private func chooseInputs(_ urls: [URL]) -> Bool {
        let local = urls.filter(\.isFileURL)
        guard !draft.busy, let first = local.first else { return false }
        error = nil
        result = nil
        if draft.mode == .create {
            for url in local where !draft.inputs.contains(url) { draft.inputs.append(url) }
        } else {
            guard local.count == 1 else {
                error = "Choose one archive at a time."
                return false
            }
            if draft.archive != first { password = "" }
            draft.archive = first
            listing = nil
            selection.removeAll()
            filter = ""
        }
        return true
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { draft.destination = panel.url }
    }

    @concurrent
    private static func rows(_ entries: [ArchiveEntry], for request: EntryRequest) async -> BrowsedEntries? {
        guard let rows = try? request.order.rows(entries, matching: request.filter) else { return nil }
        return BrowsedEntries(request: request, rows: rows, ids: Set(rows.map(\.id)))
    }

    private func select(_ entry: ArchiveEntry, on: Bool, entries: [ArchiveEntry]) {
        let prefix = entry.path + "/"
        if on {
            selection.insert(entry.id)
            if entry.isDirectory {
                selection.formUnion(entries.lazy.filter { $0.path.hasPrefix(prefix) }.map(\.id))
            }
        } else {
            selection.remove(entry.id)
            selection.subtract(entries.lazy.filter {
                (entry.isDirectory && $0.path.hasPrefix(prefix)) || ($0.isDirectory && entry.path.hasPrefix($0.path + "/"))
            }.map(\.id))
        }
    }

    private func create() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (draft.inputs.count == 1 ? draft.inputs[0].lastPathComponent : "Archive") + ".zip"
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        let inputs = draft.inputs
        let secret = protectsZIP ? password : nil
        perform("Creating ZIP…") {
            try await ArchiveTools.create(inputs, to: archive, password: secret)
            password = ""
            result = "Created \(archive.lastPathComponent)."
        }
    }

    private func readContents() {
        guard let archive = draft.archive else { return }
        let secret = password.isEmpty ? nil : password
        listing = nil
        selection.removeAll()
        perform("Reading archive…") {
            let reviewed = try await ArchiveTools.readContents(archive, password: secret)
            try Task.checkCancellation()
            listingRevision = UUID()
            listing = reviewed
            selection = Set(reviewed.entries.map(\.id))
        }
    }

    private func extract() {
        guard canExtractSelection, let archive = draft.archive, let listing, let destination = draft.destination else { return }
        let chosen = selection
        let conflicts = draft.conflicts
        let secret = password.isEmpty ? nil : password
        perform("Extracting…") {
            let summary = try await ArchiveTools.extract(archive, listing: listing, to: destination, selected: chosen,
                                                        password: secret, conflicts: conflicts)
            password = ""
            let details = [summary.renamed.isEmpty ? nil : "\(summary.renamed.count) renamed",
                           summary.skipped.isEmpty ? nil : "\(summary.skipped.count) skipped"].compactMap { $0 }
            let headline = "Extracted \(summary.published.count) top-level item\(summary.published.count == 1 ? "" : "s")"
            result = ([headline] + details).joined(separator: " · ")
        }
    }

    private func perform(_ title: String, action: @escaping @MainActor () async throws -> Void) {
        guard !draft.busy else { return }
        operation = title
        error = nil
        result = nil
        draft.busy = true
        task = Task {
            defer {
                draft.busy = false
                task = nil
            }
            do {
                try await action()
            } catch is CancellationError {
                result = "Cancelled."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
