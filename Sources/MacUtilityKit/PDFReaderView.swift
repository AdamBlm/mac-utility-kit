import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct PDFReaderView: View {
    let reader: PDFReaderSession
    let canHandoffForms: Bool
    let onHandoff: (Tool, URL) -> Void
    let stageClipboardPDF: (Data) throws -> URL

    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnails = true
    @State private var password = ""
    @State private var query = ""
    @FocusState private var searching: Bool

    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark, category: .documents) }

    var body: some View {
        VStack(spacing: 0) {
            if reader.queuedFiles.count > 1 {
                Picker("Selected PDF", selection: Binding(
                    get: { reader.source },
                    set: { if let url = $0 { reader.selectQueuedFile(url) } }
                )) {
                    let labels = ToolRunner.inputLabels(reader.queuedFiles)
                    ForEach(Array(reader.queuedFiles.enumerated()), id: \.element) { index, url in
                        Text(labels[index]).tag(Optional(url))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            if let document = reader.document, !document.isLocked {
                toolbar(document)
                if let message = reader.error {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                HStack(spacing: 0) {
                    if thumbnails {
                        PDFReaderThumbnails(pdfView: reader.view)
                            .frame(width: 102)
                        Rectangle()
                            .fill(palette.hairline)
                            .frame(width: 1)
                            .allowsHitTesting(false)
                    }
                    PDFReaderCanvas(view: reader.view)
                }
            } else if reader.document?.isLocked == true {
                ContentUnavailableView {
                    Label("Locked PDF", systemImage: "lock.doc")
                } description: {
                    Text(reader.source?.lastPathComponent ?? "")
                } actions: {
                    VStack(spacing: 10) {
                        SecureField("PDF password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                            .onSubmit(unlock)
                        Button("Unlock", action: unlock).buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                        if let message = reader.error {
                            Text(message).foregroundStyle(.secondary)
                        }
                        handoffButton(.removePassword)
                        Button("Open Another PDF…", action: choosePDF)
                        pastePDFButton
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("PDF Reader", systemImage: "book.closed")
                } description: {
                    Text(reader.error ?? "Open a PDF or drop it here.")
                } actions: {
                    Button("Open PDF…", action: choosePDF).buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                    pastePDFButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workspaceBackground(palette)
        .tint(palette.controlTint)
        .onChange(of: reader.document.map(ObjectIdentifier.init)) { _, _ in resetInputs() }
        .onDisappear { reader.resetSearch() }
        .dropDestination(for: URL.self) { urls, _ in
            let candidates = urls.filter { LocalInputFile.matches($0, allowedTypes: [.pdf]) }
            return !candidates.isEmpty && reader.openFirst(in: candidates)
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: reader.view)) { _ in
            reader.synchronizePage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFDocumentDidFindMatch)) { notification in
            reader.addSearchResult(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFDocumentDidEndFind)) { notification in
            reader.finishSearch(notification)
        }
    }

    private func toolbar(_ document: PDFDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Open PDF…", systemImage: "folder", action: choosePDF)
                    .labelStyle(.iconOnly)
                    .help("Open PDF")
                pastePDFButton
                    .labelStyle(.iconOnly)
                Text(reader.source?.lastPathComponent ?? "PDF Reader")
                    .font(.headline)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .help(reader.source?.path ?? "")
                Spacer(minLength: 0)
                Button("Print…", systemImage: "printer", action: reader.printDocument)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("p")
                    .disabled(!document.allowsPrinting)
                    .help(document.allowsPrinting ? "Print PDF" : "Printing is restricted in this PDF")
                Menu("Use in Tool", systemImage: "arrow.turn.up.right") {
                    if document.isEncrypted {
                        Text("The selected tool may ask for the PDF password again.")
                        Divider()
                        handoffButton(.removePassword)
                    }
                    ForEach([Tool.mergePDFs, .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages,
                             .pdfToImages, .signPDF, .extractText, .makePDFSearchable]) { tool in
                        handoffButton(tool)
                    }
                    handoffButton(.pdfToWord)
                        .disabled(!document.allowsCopying)
                    if !document.isEncrypted {
                        handoffButton(.addPassword)
                        handoffButton(.cropPDF)
                            .disabled(!document.allowsDocumentChanges)
                        handoffButton(.compressPDF)
                            .disabled(!document.allowsDocumentChanges)
                        handoffButton(.fillFlattenForms)
                            .disabled(!canHandoffForms || !document.allowsFormFieldEntry)
                        handoffButton(.redactPDF)
                    }
                }
                .fixedSize()
            }
            WorkspaceFlowLayout(spacing: 12) {
                pageControls(document)
                searchControls
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.barFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private func pageControls(_ document: PDFDocument) -> some View {
        HStack(spacing: 9) {
            Button(thumbnails ? "Hide thumbnails" : "Show thumbnails", systemImage: "sidebar.left") {
                thumbnails.toggle()
            }
            .labelStyle(.iconOnly)
            .help(thumbnails ? "Hide thumbnails" : "Show thumbnails")
            Button("Previous page", systemImage: "chevron.left") { reader.navigatePage(by: -1) }
                .labelStyle(.iconOnly)
                .disabled(reader.pageNumber <= 1)
            Text("\(reader.pageNumber) / \(document.pageCount)").monospacedDigit().fixedSize()
                .accessibilityLabel("Page \(reader.pageNumber) of \(document.pageCount)")
            Button("Next page", systemImage: "chevron.right") { reader.navigatePage(by: 1) }
                .labelStyle(.iconOnly)
                .disabled(reader.pageNumber >= document.pageCount)
            Divider().frame(height: 18).accessibilityHidden(true)
            Button("Zoom out", systemImage: "minus.magnifyingglass") { reader.view.zoomOut(nil) }
                .labelStyle(.iconOnly)
            Button("Fit page", systemImage: "arrow.up.left.and.arrow.down.right") { reader.view.autoScales = true }
                .labelStyle(.iconOnly)
                .help("Fit page")
            Button("Zoom in", systemImage: "plus.magnifyingglass") { reader.view.zoomIn(nil) }
                .labelStyle(.iconOnly)
        }
    }

    private func handoffButton(_ tool: Tool) -> some View {
        Button(tool.title) {
            if let input = reader.source { onHandoff(tool, input) }
        }
    }

    private var searchControls: some View {
        HStack(spacing: 5) {
            TextField("Find in PDF", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 95, idealWidth: 145, maxWidth: 185)
                .focused($searching)
                .onSubmit { reader.search(query) }
                .onChange(of: query) { reader.resetSearch() }
            Button("Find in PDF", systemImage: "magnifyingglass") {
                if searching {
                    reader.search(query)
                } else {
                    searching = true
                }
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("f")
            if reader.isSearching {
                ProgressView().controlSize(.small)
            }
            if let match = reader.matchStatus {
                Text(match).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            if reader.hasMatches {
                Button("Previous match", systemImage: "chevron.up") { reader.navigateMatch(by: -1) }
                    .labelStyle(.iconOnly)
                Button("Next match", systemImage: "chevron.down") { reader.navigateMatch(by: 1) }
                    .labelStyle(.iconOnly)
            }
        }
    }

    private var pastePDFButton: some View {
        ClipboardFileButton(allowedTypes: [.pdf], stagePDF: stageClipboardPDF) { urls in
            _ = reader.openFirst(in: urls)
        }
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { _ = reader.openFirst(in: panel.urls) }
    }

    private func resetInputs() {
        password = ""
        query = ""
    }

    private func unlock() {
        reader.unlock(password)
        password = ""
    }
}

struct PDFReaderCanvas: NSViewRepresentable {
    let view: PDFView

    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

private struct PDFReaderThumbnails: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnails = PDFThumbnailView()
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.thumbnailSize = CGSize(width: 82, height: 103)
        thumbnails.allowsMultipleSelection = false
        thumbnails.allowsDragging = false
        thumbnails.backgroundColor = .controlBackgroundColor
        thumbnails.pdfView = pdfView
        return thumbnails
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== pdfView { nsView.pdfView = pdfView }
    }
}
