import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct PDFRedactionDraft {
    var input: URL?
    var fingerprint: String?
    var marks: [PDFRedactionMark] = []
    var fill = PDFRedactionFill.black
}

struct RedactPDFView: View {
    @Binding var draft: PDFRedactionDraft
    let stageClipboardPDF: (Data) throws -> URL
    @State private var preview = PDFRedactionPreviewSession()
    @State private var loaded: Loaded?
    @State private var mode = Mode.text
    @State private var focusedMark: UUID?
    @State private var fileRevision = UUID()
    @State private var search = ""
    @State private var work: Task<Void, Never>?
    @State private var operation: Operation?
    @State private var progress = 0.0
    @State private var issue: String?
    @State private var status: String?
    @State private var saved: URL?

    private enum Mode: String, CaseIterable, Identifiable {
        case text = "Select text", region = "Draw rectangle"
        var id: Self { self }
    }

    private enum Operation { case search, export }

    private struct Loaded {
        let url: URL
        let source: PDFRedactionSource
    }

    private struct SourceIdentity: Equatable {
        let url: URL?
        let revision: UUID
    }

    var body: some View {
        ScrollViewReader { scroll in
            InteractiveToolLayout(tool: .redactPDF) { palette in
                WorkspaceSection("PDF", palette: palette) {
                    HStack {
                        Button(draft.input == nil ? "Choose PDF…" : "Replace PDF…", systemImage: "folder") { choose() }
                        ClipboardFileButton(allowedTypes: [.pdf], onPastePDF: { data in
                            setInput(try stageClipboardPDF(data))
                        }, onPasteFile: setInput)
                        if let input = draft.input { Text(input.lastPathComponent).lineLimit(1).foregroundStyle(.secondary) }
                    }
                    .disabled(work != nil)
                }
                if let loaded, loaded.url == draft.input {
                    WorkspaceSection("Mark content", palette: palette) {
                        editor(loaded)
                            .id("redaction-preview")
                    }
                    if !draft.marks.isEmpty {
                        WorkspaceSection("Review marks", palette: palette) {
                            reviews {
                                withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo("redaction-preview", anchor: .top) }
                            }
                        }
                    }
                    WorkspaceSection("Export", palette: palette) { exportControls(loaded) }
                }
                if let issue { Text(issue).font(.callout).foregroundStyle(.red) }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                if let saved {
                    Button("Reveal Redacted PDF", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([saved])
                    }
                }
            }
        }
        .task(id: SourceIdentity(url: draft.input, revision: fileRevision)) { await load(draft.input) }
        .onChange(of: draft.marks) { synchronizeOverlays() }
        .onChange(of: draft.fill) { synchronizeOverlays() }
        .onChange(of: focusedMark) { synchronizeOverlays() }
        .dropDestination(for: URL.self) { urls, _ in
            guard work == nil, urls.count == 1, let url = urls.first, url.isFileURL,
                  url.pathExtension.lowercased() == "pdf" else { return false }
            setInput(url)
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: preview.view)) { _ in
            preview.synchronize()
            synchronizeOverlays()
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewSelectionChanged, object: preview.view)) { _ in
            preview.synchronize()
        }
        .onDisappear { work?.cancel() }
    }

    private func editor(_ loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Marking method", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                TextField("Find text in the PDF", text: $search)
                Button("Mark Matches", systemImage: "magnifyingglass") { markMatches(loaded) }
                    .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Previous Page", systemImage: "chevron.left") { preview.navigate(preview.pageNumber - 1) }
                    .labelStyle(.iconOnly)
                    .disabled(preview.pageNumber <= 1)
                Picker("Page", selection: Binding(get: { preview.pageNumber }, set: { preview.navigate($0) })) {
                    ForEach(1...loaded.source.pageCount, id: \.self) { number in Text("Page \(number)").tag(number) }
                }
                .labelsHidden()
                Button("Next Page", systemImage: "chevron.right") { preview.navigate(preview.pageNumber + 1) }
                    .labelStyle(.iconOnly)
                    .disabled(preview.pageNumber >= loaded.source.pageCount)
                Spacer()
                if mode == .text {
                    Button("Mark Selected Text", systemImage: "selection.pin.in.out") { add(preview.selectedMarks()) }
                        .disabled(!preview.hasSelection)
                }
            }
            if !draft.marks.isEmpty {
                let adjacent = PDFRedaction.adjacentMarkedPages(to: preview.pageNumber, in: draft.marks)
                HStack {
                    Button("Previous Marked Page", systemImage: "chevron.left") {
                        if let page = adjacent.previous { revealMarkedPage(page) }
                    }
                    .disabled(adjacent.previous == nil)
                    Button("Next Marked Page", systemImage: "chevron.right") {
                        if let page = adjacent.next { revealMarkedPage(page) }
                    }
                    .disabled(adjacent.next == nil)
                }
            }
            PDFRedactionPreview(session: preview, drawsRectangles: mode == .region) { add([$0]) }
                .frame(minHeight: 320, idealHeight: 380)
                .clipShape(.rect(cornerRadius: 8))
            if mode == .region {
                Text("Drag over the area to remove.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .disabled(work != nil)
    }

    private func revealMarkedPage(_ page: Int) {
        focusedMark = nil
        preview.navigate(page)
    }

    private func reviews(reveal: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingRow("Fill") {
                Picker("Redaction fill", selection: $draft.fill) {
                    ForEach(PDFRedactionFill.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            let byPage = Dictionary(grouping: draft.marks, by: \.page)
            ForEach(byPage.keys.sorted(), id: \.self) { page in
                Button("Page \(page)", systemImage: "doc") {
                    revealMarkedPage(page)
                    reveal()
                }
                .buttonStyle(.plain).font(.callout.weight(.semibold))
                ForEach(Array(byPage[page, default: []].enumerated()), id: \.element.id) { index, mark in
                    HStack {
                        Text("\(mark.kind.rawValue) \(index + 1)").font(.callout)
                        Spacer()
                        Button("Preview mark", systemImage: "eye") {
                            focusedMark = mark.id
                            preview.navigate(mark.page)
                            reveal()
                        }
                        .labelStyle(.iconOnly)
                        Button("Remove mark", systemImage: "xmark.circle") { draft.marks.removeAll { $0.id == mark.id } }
                            .labelStyle(.iconOnly)
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .disabled(work != nil)
    }

    private func exportControls(_ loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The exported copy keeps visible page content as images. Searchable text, annotations, forms, links and document metadata are removed.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Export Redacted Copy…", systemImage: "square.and.arrow.up") { export(loaded) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.marks.isEmpty || work != nil)
                if let operation {
                    if operation == .export {
                        ProgressView(value: progress).frame(maxWidth: 155)
                    } else {
                        ProgressView("Searching…").controlSize(.small)
                    }
                    Button("Cancel") { work?.cancel() }
                }
            }
        }
    }

    private func choose() {
        guard let input = DeveloperToolFiles.choose(allowedTypes: [.pdf]) else { return }
        setInput(input)
    }

    private func setInput(_ input: URL) {
        if draft.input != input {
            draft.marks = []
            draft.fingerprint = nil
        }
        draft.input = input
        fileRevision = UUID()
    }

    private func load(_ input: URL?) async {
        loaded = nil
        focusedMark = nil
        issue = nil
        status = nil
        saved = nil
        search = ""
        preview.open(nil)
        guard let input else { return }
        do {
            let source = try await PDFRedaction.open(input)
            guard !Task.isCancelled else { return }
            if let fingerprint = draft.fingerprint, fingerprint != source.fingerprint {
                draft.marks = []
                issue = "The PDF changed. Review and mark the new version."
            }
            draft.fingerprint = source.fingerprint
            loaded = Loaded(url: input, source: source)
            preview.open(source)
            synchronizeOverlays()
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }

    private func add(_ marks: [PDFRedactionMark]) {
        let candidates = marks.filter { mark in !draft.marks.contains { $0.page == mark.page && $0.rect == mark.rect } }
        draft.marks.append(contentsOf: candidates)
        status = candidates.isEmpty ? "No new marks." : "Added \(candidates.count) mark\(candidates.count == 1 ? "" : "s")."
        if let first = candidates.first, first.page != preview.pageNumber { preview.navigate(first.page) }
    }

    private func synchronizeOverlays() { preview.show(draft.marks, fill: draft.fill, focused: focusedMark) }

    private func markMatches(_ loaded: Loaded) {
        let phrase = search
        issue = nil
        status = nil
        operation = .search
        work = Task {
            defer { work = nil; operation = nil }
            do {
                let matched = try await PDFRedaction.search(phrase, in: loaded.source)
                try Task.checkCancellation()
                if matched.isEmpty { status = "No searchable text matches." }
                else { add(matched) }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    private func export(_ loaded: Loaded) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = loaded.url.deletingPathExtension().lastPathComponent + "-redacted.pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let confirmed: PDFFormDestination
        do {
            confirmed = try PDFFormDestination(destination, preserving: loaded.source.url)
        } catch {
            issue = error.localizedDescription
            return
        }
        let marks = draft.marks
        let fill = draft.fill
        issue = nil
        status = nil
        saved = nil
        progress = 0
        operation = .export
        work = Task {
            defer { work = nil; operation = nil }
            do {
                let result = try await PDFRedaction.export(
                    loaded.source, marks: marks, fill: fill, destination: confirmed
                ) { fraction in
                    await MainActor.run { progress = fraction }
                }
                saved = confirmed.url
                let suffix = result.markedPageCount == 1 ? "page" : "pages"
                status = "Saved the redacted copy with marks on \(result.markedPageCount) \(suffix)."
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}
