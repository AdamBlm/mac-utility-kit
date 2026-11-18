import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct PDFReaderView: View {
    @Binding var source: URL?
    let onHandoff: (Tool, URL) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var reader = PDFReaderSession()
    @State private var thumbnails = true
    @State private var password = ""
    @State private var query = ""
    @FocusState private var searching: Bool

    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            if let document = reader.document, !document.isLocked {
                toolbar(document)
                Divider()
                HStack(spacing: 0) {
                    if thumbnails {
                        PDFReaderThumbnails(pdfView: reader.view)
                            .frame(width: 112)
                        Divider()
                    }
                    PDFReaderCanvas(view: reader.view)
                }
            } else if reader.document?.isLocked == true {
                ContentUnavailableView {
                    Label("Locked PDF", systemImage: "lock.doc")
                } description: {
                    Text(source?.lastPathComponent ?? "")
                } actions: {
                    VStack(spacing: 10) {
                        SecureField("PDF password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                            .onSubmit(unlock)
                        Button("Unlock", action: unlock).buttonStyle(.borderedProminent)
                        if let message = reader.error {
                            Text(message).foregroundStyle(.secondary)
                        }
                        Button("Open Another PDF…", action: choosePDF)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("PDF Reader", systemImage: "book.closed")
                } description: {
                    Text(reader.error ?? "Open a PDF or drop it here.")
                } actions: {
                    Button("Open PDF…", action: choosePDF).buttonStyle(.borderedProminent)
                }
            }
        }
        .background(palette.canvas)
        .onChange(of: source, initial: true) { previous, next in
            if previous != next || reader.source != next { load(next) }
        }
        .onDisappear { reader.cancelSearch() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let pdf = urls.first(where: { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }) else {
                return false
            }
            open(pdf)
            return true
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
                Text(source?.lastPathComponent ?? "PDF Reader")
                    .font(.headline)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .help(source?.path ?? "")
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
                    }
                    ForEach([Tool.mergePDFs, .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages,
                             .pdfToImages, .signPDF, .extractText]) { tool in
                        Button(tool.title) {
                            if let source { onHandoff(tool, source) }
                        }
                    }
                }
                .fixedSize()
            }
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
                Divider().frame(height: 18)
                Button("Zoom out", systemImage: "minus.magnifyingglass") { reader.view.zoomOut(nil) }
                    .labelStyle(.iconOnly)
                Button("Fit page", systemImage: "arrow.up.left.and.arrow.down.right") { reader.view.autoScales = true }
                    .labelStyle(.iconOnly)
                    .help("Fit page")
                Button("Zoom in", systemImage: "plus.magnifyingglass") { reader.view.zoomIn(nil) }
                    .labelStyle(.iconOnly)
                Spacer(minLength: 0)
                searchControls
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.surface)
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

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func open(_ url: URL) {
        if source == url { load(url) }
        else { source = url }
    }

    private func load(_ url: URL?) {
        password = ""
        query = ""
        reader.open(url)
    }

    private func unlock() {
        reader.unlock(password)
        password = ""
    }
}

private struct PDFReaderCanvas: NSViewRepresentable {
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
