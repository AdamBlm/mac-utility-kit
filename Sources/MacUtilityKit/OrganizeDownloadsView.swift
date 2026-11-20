import AppKit
import QuickLook
import SwiftUI
import UtilityCore

struct OrganizeDownloadsDraft {
    var source: URL?
    var includesSubfolders = false
    var items: [DownloadImage] = []
    var selected: Set<URL> = []
    var busy = false
    var result: DownloadsResult?
    var issue: String?
}

struct OrganizeDownloadsView: View {
    @Binding var draft: OrganizeDownloadsDraft
    @State private var originFilter = ""
    @State private var typeFilter = ""
    @State private var preview: URL?
    @State private var pending: FileRequest?
    @State private var pendingPhotos: [DownloadImage]?

    private struct FileRequest {
        let destination: DownloadDestination
        let entries: [DownloadImage]
    }

    private var originNames: [String] { Set(draft.items.map(originName)).sorted() }
    private var fileTypes: [String] { Set(draft.items.map(\.fileType)).sorted() }

    private var visible: [String: [DownloadImage]] {
        Dictionary(grouping: draft.items.filter { item in
            (originFilter.isEmpty || originName(item) == originFilter) && (typeFilter.isEmpty || item.fileType == typeFilter)
        }, by: originName)
    }

    private var reviewedSelection: [DownloadImage]? {
        OrganizeDownloads.reviewedSelection(from: draft.items, selected: draft.selected,
                                            visible: Set(visible.values.joined().map(\.file)))
    }

    var body: some View {
        let groups = visible
        let visibleFiles = Set(groups.values.joined().map(\.file))
        InteractiveToolLayout(tool: .organizeDownloads) { palette in
            WorkspaceSection("Source Folder", palette: palette) {
                HStack {
                    Button("Choose Folder…", systemImage: "folder", action: chooseSource)
                    if draft.source != nil {
                        Button("Scan Again", systemImage: "arrow.clockwise") {
                            if let folder = draft.source { scan(folder) }
                        }
                    }
                    if draft.busy { ProgressView().controlSize(.small) }
                }
                .disabled(draft.busy)
                Toggle("Include subfolders", isOn: $draft.includesSubfolders)
                    .disabled(draft.busy)
                if let path = draft.source?.path { Text(path).font(.callout).textSelection(.enabled) }
                if draft.source != nil && draft.items.isEmpty && !draft.busy && draft.issue == nil {
                    Text("No images were found in the folder.").foregroundStyle(.secondary)
                }
                if let issue = draft.issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            }
            if !draft.items.isEmpty {
                WorkspaceSection("Images", palette: palette) {
                    HStack {
                        Picker("Origin", selection: $originFilter) {
                            Text("All origins").tag("")
                            ForEach(originNames, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Type", selection: $typeFilter) {
                            Text("All image types").tag("")
                            ForEach(fileTypes, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    ForEach(groups.keys.sorted(), id: \.self) { origin in
                        if let items = groups[origin] { group(origin, items: items) }
                    }
                }
                WorkspaceSection("Export Selection", palette: palette) {
                    let hidden = draft.selected.subtracting(visibleFiles).count
                    Text("\(draft.selected.count) images selected")
                    if hidden > 0 {
                        HStack {
                            Text(hidden == 1 ? "One selected image is hidden by the filters."
                                 : "\(hidden) selected images are hidden by the filters.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Clear Filters") {
                                originFilter = ""
                                typeFilter = ""
                            }
                        }
                    }
                    HStack {
                        Button("Copy to Folder…", systemImage: "folder.badge.plus") { chooseDestination(move: false) }
                        Button("Move to Folder…", systemImage: "arrow.right.circle") { chooseDestination(move: true) }
                        Button("Import into Photos…", systemImage: "photo.on.rectangle") {
                            guard let entries = reviewedSelection else { return }
                            pendingPhotos = entries
                        }
                    }
                    .disabled(draft.busy || draft.selected.isEmpty || hidden > 0)
                }
            }
            if let result = draft.result {
                WorkspaceSection("Results", palette: palette) {
                    Text((result.wasCancelled ? "Stopped · " : "")
                         + "\(result.completed.count) completed · \(result.skipped.count) skipped · \(result.failures.count) failed")
                    if !result.completed.isEmpty {
                        DisclosureGroup("Completed Items") {
                            ForEach(Array(result.completed.enumerated()), id: \.offset) { _, detail in
                                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    ForEach(Array((result.skipped + result.failures).enumerated()), id: \.offset) { _, detail in
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .quickLookPreview($preview)
        .onChange(of: draft.includesSubfolders) {
            if let source = draft.source { scan(source) }
        }
        .confirmationDialog("Move selected images?", isPresented: Binding(get: { pending != nil }, set: { shown in
            if !shown { pending = nil }
        }), titleVisibility: .visible, presenting: pending) { request in
            Button("Move Images") { export(request, action: .move) }
        } message: { request in
            Text("Move \(request.entries.count) images out of their original folder.")
        }
        .confirmationDialog("Import images into Photos?", isPresented: Binding(get: { pendingPhotos != nil }, set: { shown in
            if !shown { pendingPhotos = nil }
        }), titleVisibility: .visible, presenting: pendingPhotos) { entries in
            Button("Import Images") { importPhotos(entries) }
        } message: { entries in
            Text("Import \(entries.count) images into albums grouped by origin. The original files stay in place.")
        }
    }

    private func group(_ origin: String, items: [DownloadImage]) -> some View {
        DisclosureGroup("\(origin) · \(items.count)") {
            let urls = Set(items.map(\.file))
            HStack {
                Button("Select Group") { draft.selected.formUnion(urls) }
                Button("Clear Group") { draft.selected.subtract(urls) }
            }
            .disabled(draft.busy)
            LazyVStack(alignment: .leading) {
                ForEach(items) { item in
                    HStack {
                        Toggle(item.relativePath, isOn: Binding(
                            get: { draft.selected.contains(item.file) },
                            set: { on in
                                if on { draft.selected.insert(item.file) }
                                else { draft.selected.remove(item.file) }
                            }
                        ))
                        .disabled(draft.busy)
                        Spacer()
                        Text(item.fileType).font(.caption).foregroundStyle(.secondary)
                        Button("Preview", systemImage: "eye") { preview = item.file }
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
    }

    private func originName(_ item: DownloadImage) -> String {
        item.origin ?? "Unknown Source"
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseSource() {
        if let folder = chooseFolder() { scan(folder) }
    }

    private func scan(_ directory: URL) {
        draft.busy = true
        draft.issue = nil
        draft.source = directory
        draft.items = []
        draft.selected = []
        originFilter = ""
        typeFilter = ""
        let includesSubfolders = draft.includesSubfolders
        Task {
            defer { draft.busy = false }
            do {
                draft.items = try await Task.detached {
                    try OrganizeDownloads.scan(directory, includesSubfolders: includesSubfolders)
                }.value
            } catch { draft.issue = error.localizedDescription }
        }
    }

    private func chooseDestination(move: Bool) {
        guard !draft.busy, reviewedSelection != nil, let destination = chooseFolder(),
              let entries = reviewedSelection else { return }
        do {
            let approval = try OrganizeDownloads.inspectDestination(destination)
            let request = FileRequest(destination: approval, entries: entries)
            if move { pending = request }
            else { export(request, action: .copy) }
        } catch { draft.issue = error.localizedDescription }
    }

    private func export(_ request: FileRequest, action: OrganizeDownloads.FileAction) {
        guard !draft.busy, reviewedSelection?.map(\.file) == request.entries.map(\.file) else { return }
        draft.busy = true
        draft.issue = nil
        draft.result = nil
        Task {
            defer { draft.busy = false }
            do {
                let worker = Task.detached {
                    try OrganizeDownloads.export(request.entries, to: request.destination, action: action)
                }
                let center = ExportActivityCenter.shared
                let job = center.start(.organizeDownloads) { worker.cancel() }
                defer { center.finish(job) }
                draft.result = try await worker.value
                if action == .move, let source = draft.source {
                    let includesSubfolders = draft.includesSubfolders
                    draft.items = try await Task.detached {
                        try OrganizeDownloads.scan(source, includesSubfolders: includesSubfolders)
                    }.value
                    draft.selected.formIntersection(draft.items.map(\.file))
                }
            } catch { draft.issue = error.localizedDescription }
        }
    }

    private func importPhotos(_ entries: [DownloadImage]) {
        guard !draft.busy, reviewedSelection?.map(\.file) == entries.map(\.file) else { return }
        draft.busy = true
        draft.issue = nil
        draft.result = nil
        Task {
            defer { draft.busy = false }
            let worker = Task { try await DownloadPhotoAlbums.importSelected(entries) }
            let center = ExportActivityCenter.shared
            let job = center.start(.organizeDownloads) { worker.cancel() }
            defer { center.finish(job) }
            do { draft.result = try await worker.value }
            catch { draft.issue = error.localizedDescription }
        }
    }
}
