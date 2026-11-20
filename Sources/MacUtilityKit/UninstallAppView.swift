import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct UninstallAppDraft {
    var source: URL?
    var report: UninstallApp.Report?
    var selected: Set<URL> = []
    var result: UninstallApp.Result?
    var removalTask: Task<Void, Never>?
    var removing: Bool { removalTask != nil }
}

struct UninstallAppView: View {
    @Binding var draft: UninstallAppDraft
    @State private var reviewTask: Task<Void, Never>?
    @State private var progress: UninstallApp.Progress?
    @State private var error: String?
    @State private var confirmation = false

    private var busy: Bool { reviewTask != nil || draft.removing }

    var body: some View {
        InteractiveToolLayout(tool: .uninstallApp) { palette in
            WorkspaceSection("Application", palette: palette) {
                sourceControls
            }
            if let report = draft.report {
                WorkspaceSection("Review Items", palette: palette) { items(report) }
            }
            if let result = draft.result {
                WorkspaceSection("Trash Results", palette: palette) { results(result) }
            }
        }
        .onDisappear { reviewTask?.cancel() }
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy, let url = urls.first, urls.count == 1, url.isFileURL,
                  url.pathExtension.lowercased() == "app" else { return false }
            choose(url)
            return true
        }
        .confirmationDialog("Move selected items to Trash?", isPresented: $confirmation, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive, action: moveSelection)
        } message: {
            if let report = draft.report {
                let selected = report.items.filter { draft.selected.contains($0.id) }
                let names = selected.map { $0.kind.rawValue }.joined(separator: ", ")
                Text("\(report.name) · \(names)")
            }
        }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose App…", systemImage: "app", action: open)
                if let source = draft.source {
                    Text(source.lastPathComponent).lineLimit(1).help(source.path)
                    Button("Review Again", systemImage: "arrow.clockwise", action: review)
                }
            }
            .disabled(busy)
            Text("Review an app in Applications or your home Applications folder.")
                .font(.callout).foregroundStyle(.secondary)
            if let progress, reviewTask != nil {
                HStack {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))) {
                        Text("Checking \(progress.current.lastPathComponent)…").lineLimit(1)
                    }
                    Button("Cancel") { reviewTask?.cancel() }
                }
                .font(.callout)
            } else if reviewTask != nil {
                HStack {
                    ProgressView("Reviewing application…").controlSize(.small)
                    Button("Cancel") { reviewTask?.cancel() }
                }
            }
            if let removalTask = draft.removalTask {
                HStack {
                    ProgressView("Rechecking and moving items…").controlSize(.small)
                    Button("Stop") { removalTask.cancel() }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func items(_ report: UninstallApp.Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.bundleIdentifier).font(.callout.monospaced()).textSelection(.enabled)
                .foregroundStyle(.secondary)
            if report.associatedItemsShared {
                Text("Associated files are unavailable because their ownership is shared or could not be confirmed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(report.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Toggle(isOn: Binding(get: { draft.selected.contains(item.id) }, set: { enabled in
                        if enabled { draft.selected.insert(item.id) } else { draft.selected.remove(item.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.kind.rawValue).font(.headline)
                            Text(item.url.path).lineLimit(1).truncationMode(.middle).help(item.url.path)
                            Text(item.kind.rationale).foregroundStyle(.secondary)
                            if let issue = item.issue { Text(issue).foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!item.canTrash)
                    Spacer()
                    if let size = item.estimatedBytes {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                    }
                    if item.canTrash {
                        Button("Reveal \(item.kind.rawValue) in Finder", systemImage: "arrow.up.right.square") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                if item.id != report.items.last?.id { Divider() }
            }
            HStack {
                Button("Move Selected to Trash…", systemImage: "trash") { confirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.selected.isEmpty)
                if !draft.selected.isEmpty {
                    Text("\(draft.selected.count) selected").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(busy)
    }

    private func results(_ result: UninstallApp.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let count = result.moved.count
            Text((result.wasCancelled ? "Stopped. " : "") + "\(count) item\(count == 1 ? "" : "s") moved to Trash.")
            ForEach(result.issues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.url.path).lineLimit(1).truncationMode(.middle).help(issue.url.path)
                    Text(issue.reason).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private func open() {
        guard let url = DeveloperToolFiles.choose(allowedTypes: [.applicationBundle]) else { return }
        choose(url)
    }

    private func choose(_ url: URL) {
        draft.source = url
        draft.result = nil
        review()
    }

    private func review() {
        guard !busy, let source = draft.source else { return }
        draft.report = nil
        draft.selected.removeAll()
        error = nil
        progress = nil
        reviewTask = Task {
            defer { reviewTask = nil; progress = nil }
            do {
                let report = try await UninstallApp.review(source) { update in
                    await MainActor.run { progress = update }
                }
                try Task.checkCancellation()
                draft.report = report
                draft.selected = report.defaultSelection
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func moveSelection() {
        guard !busy, let report = draft.report, !draft.selected.isEmpty else { return }
        let selected = draft.selected
        error = nil
        draft.removalTask = Task {
            defer { draft.removalTask = nil }
            let result = await UninstallApp.trash(selected, from: report)
            draft.result = result
            draft.report = nil
            draft.selected.removeAll()
            if result.moved.contains(report.application) { draft.source = nil }
        }
    }
}
