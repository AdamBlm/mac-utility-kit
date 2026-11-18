import AppKit
import QuickLook
import SwiftUI
import UtilityCore

struct OrganizeDownloadsDraft {
    var source: URL?
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
    @State private var confirmPhotos = false

    private struct FileRequest {
        let destination: DownloadDestination
        let entries: [DownloadImage]
    }

    private var chosen: [DownloadImage] { draft.items.filter { draft.selected.contains($0.file) } }
    private var originNames: [String] { Set(draft.items.map(originName)).sorted() }
    private var fileTypes: [String] { Set(draft.items.map(\.fileType)).sorted() }

    private var visible: [String: [DownloadImage]] {
        Dictionary(grouping: draft.items.filter { item in
            (originFilter.isEmpty || originName(item) == originFilter) && (typeFilter.isEmpty || item.fileType == typeFilter)
        }, by: originName)
    }

    var body: some View {
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
                    ForEach(visible.keys.sorted(), id: \.self) { origin in
                        if let items = visible[origin] { group(origin, items: items) }
                    }
                }
                WorkspaceSection("Export Selection", palette: palette) {
                    Text("\(draft.selected.count) images selected")
                    HStack {
                        Button("Copy to Folder…", systemImage: "folder.badge.plus") { chooseDestination(move: false) }
                        Button("Move to Folder…", systemImage: "arrow.right.circle") { chooseDestination(move: true) }
                        Button("Import into Photos…", systemImage: "photo.on.rectangle") { confirmPhotos = true }
                    }
                    .disabled(draft.busy || draft.selected.isEmpty)
                }
            }
            if let result = draft.result {
                WorkspaceSection("Results", palette: palette) {
                    Text("\(result.completed.count) completed · \(result.skipped.count) skipped · \(result.failures.count) failed")
                    ForEach(Array((result.skipped + result.failures).enumerated()), id: \.offset) { _, detail in
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .quickLookPreview($preview)
        .confirmationDialog("Move selected images?", isPresented: Binding(get: { pending != nil }, set: { shown in
            if !shown { pending = nil }
        }), titleVisibility: .visible, presenting: pending) { request in
            Button("Move Images") { export(request, action: .move) }
        } message: { request in
            Text("Move \(request.entries.count) images out of their original folder.")
        }
        .confirmationDialog("Import images into Photos?", isPresented: $confirmPhotos, titleVisibility: .visible) {
            Button("Import Images") { importPhotos() }
        } message: {
            Text("Create albums grouped by origin and keep the original files in place.")
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
                        Toggle(item.file.lastPathComponent, isOn: Binding(
                            get: { draft.selected.contains(item.file) },
                            set: { on in
                                if on { draft.selected.insert(item.file) }
                                else { draft.selected.remove(item.file) }
                            }
                        ))
                        .disabled(draft.busy)
                        Spacer()
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
        Task {
            defer { draft.busy = false }
            do {
                draft.items = try await Task.detached { try OrganizeDownloads.scan(directory) }.value
            } catch { draft.issue = error.localizedDescription }
        }
    }

    private func chooseDestination(move: Bool) {
        guard let destination = chooseFolder() else { return }
        do {
            let approval = try OrganizeDownloads.inspectDestination(destination)
            let request = FileRequest(destination: approval, entries: chosen)
            if move { pending = request }
            else { export(request, action: .copy) }
        } catch { draft.issue = error.localizedDescription }
    }

    private func export(_ request: FileRequest, action: OrganizeDownloads.FileAction) {
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
                    draft.items = try await Task.detached { try OrganizeDownloads.scan(source) }.value
                    draft.selected.formIntersection(draft.items.map(\.file))
                }
            } catch { draft.issue = error.localizedDescription }
        }
    }

    private func importPhotos() {
        let entries = chosen
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
