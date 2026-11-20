import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore
import WebKit

struct MarkdownPDFDraft {
    var markdown = ""
    var source: URL?
    var options = MarkdownPDFOptions()
}

struct MarkdownPDFView: View {
    @Binding var draft: MarkdownPDFDraft
    @State private var prepared: MarkdownPDFDocument?
    @State private var completed: Request?
    @State private var previewError: String?
    @State private var fileError: String?
    @State private var renderedPreview: RenderedPDFPreview?
    @State private var exportError: String?
    @State private var task: Task<Void, Never>?

    private struct Request: Equatable, Sendable {
        let markdown: String
        let options: MarkdownPDFOptions

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.options == rhs.options && lhs.markdown.utf8.elementsEqual(rhs.markdown.utf8)
        }
    }

    private var inputTypes: [UTType] {
        [UTType(filenameExtension: "md") ?? .plainText, .plainText]
    }

    var body: some View {
        let request = Request(markdown: draft.markdown, options: draft.options)
        InteractiveToolLayout(tool: .markdownToPDF) { palette in
            WorkspaceSection("Markdown", palette: palette) {
                TextEditor(text: $draft.markdown)
                    .font(.body.monospaced())
                    .frame(minHeight: 170, idealHeight: 215)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Markdown source")
                HStack {
                    Button("Open Markdown…", systemImage: "folder") {
                        if let url = DeveloperToolFiles.choose(allowedTypes: inputTypes) { open(url) }
                    }
                    ClipboardFileButton(allowedTypes: inputTypes, buttonOnlyTitle: "Paste File", onPasteFile: open)
                    Button("Paste Text", systemImage: "doc.on.clipboard") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            draft.markdown = text
                            draft.source = nil
                            fileError = nil
                        }
                    }
                    Spacer()
                    if let source = draft.source {
                        Text(source.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).help(source.path)
                    }
                }
                SettingRow("Image folder") {
                    if let url = draft.options.imageFolder {
                        Text(url.lastPathComponent).lineLimit(1).help(url.path)
                    }
                    Button("Choose…", action: chooseFolder)
                    if draft.options.imageFolder != nil {
                        Button("Remove Folder", systemImage: "xmark.circle") { draft.options.imageFolder = nil }
                            .labelStyle(.iconOnly)
                    } else if let source = draft.source {
                        Button("Use File’s Folder") { draft.options.imageFolder = source.deletingLastPathComponent() }
                    }
                }
                if let fileError { Text(fileError).font(.callout).foregroundStyle(.red) }
            }
            .disabled(task != nil)

            WorkspaceSection("Page Setup", palette: palette) {
                SettingRow("Theme") {
                    Picker("Theme", selection: $draft.options.theme) {
                        ForEach(MarkdownPDFTheme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                SettingRow("Paper") {
                    Picker("Paper", selection: $draft.options.paper) {
                        ForEach(PDFPrintPaper.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                SettingRow("Margins") {
                    Picker("Margins", selection: $draft.options.margin) {
                        ForEach(PDFPrintMargin.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            .disabled(task != nil)

            WorkspaceSection("Preview", palette: palette) {
                if completed == request, let prepared {
                    if !prepared.imageIssues.isEmpty {
                        DisclosureGroup("Unavailable images (\(prepared.imageIssues.count))") {
                            ForEach(Array(prepared.imageIssues.prefix(20).enumerated()), id: \.offset) { _, issue in
                                Text(issue).font(.callout).foregroundStyle(.secondary)
                            }
                            if prepared.imageIssues.count > 20 {
                                Text("Additional issues omitted.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    MarkdownHTMLPreview(html: prepared.html, document: prepared)
                        .frame(minHeight: 300, idealHeight: 410, maxHeight: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Rendered Markdown preview")
                    HStack {
                        Button("Preview PDF", systemImage: "doc.viewfinder") { render(prepared, showPreview: true) }
                            .disabled(task != nil)
                        Button("Export PDF…", systemImage: "square.and.arrow.up") { render(prepared, showPreview: false) }
                            .buttonStyle(.borderedProminent)
                            .disabled(task != nil)
                        if task != nil {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { task?.cancel() }
                        }
                    }
                    if let exportError { Text(exportError).font(.callout).foregroundStyle(.red) }
                } else if completed == request, let previewError {
                    Text(previewError).font(.callout).foregroundStyle(.red)
                } else if !request.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ProgressView("Preparing preview…").controlSize(.small)
                } else {
                    Text("Enter or open Markdown to preview it.").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: request) { await prepare(request) }
        .dropDestination(for: URL.self) { urls, _ in
            guard task == nil, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            let allowed = ["md", "markdown", "txt", "mdown"]
            guard allowed.contains(url.pathExtension.lowercased()) else { return false }
            open(url)
            return true
        }
        .onDisappear { task?.cancel() }
        .sheet(item: $renderedPreview) { preview in RenderedPDFPreviewSheet(preview: preview) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = draft.options.imageFolder ?? draft.source?.deletingLastPathComponent()
        if panel.runModal() == .OK, let directory = panel.url { draft.options.imageFolder = directory }
    }

    private func open(_ source: URL) {
        guard task == nil else { return }
        fileError = nil
        task = Task {
            defer { task = nil }
            do {
                let text = try await MarkdownPDF.loadUTF8(source)
                try Task.checkCancellation()
                draft.markdown = text
                draft.source = source
                draft.options.imageFolder = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                fileError = error.localizedDescription
            }
        }
    }

    private func prepare(_ request: Request) async {
        prepared = nil
        previewError = nil
        exportError = nil
        guard !request.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(220))
            let result = try await MarkdownPDF.prepare(request.markdown, options: request.options)
            try Task.checkCancellation()
            prepared = result
            completed = request
        } catch is CancellationError {
            return
        } catch {
            previewError = error.localizedDescription
            completed = request
        }
    }

    private func render(_ document: MarkdownPDFDocument, showPreview: Bool) {
        guard task == nil else { return }
        let filename = (draft.source?.deletingPathExtension().lastPathComponent ?? "Markdown") + ".pdf"
        exportError = nil
        task = Task {
            defer { task = nil }
            do {
                let data = try await MarkdownPDFPrint.render(document)
                try Task.checkCancellation()
                if showPreview {
                    renderedPreview = try RenderedPDFPreview(data: data, filename: filename)
                } else {
                    try DeveloperToolFiles.save(data, as: filename)
                }
            } catch is CancellationError {
                return
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

private struct MarkdownHTMLPreview: NSViewRepresentable {
    let html: String
    let document: MarkdownPDFDocument

    @MainActor final class Coordinator {
        var page = MarkdownPDFWebPage()
        var rendered: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.page.webView }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.rendered != html {
            context.coordinator.rendered = html
            context.coordinator.page.show(document)
        }
    }
}
