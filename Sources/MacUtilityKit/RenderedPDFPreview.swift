import PDFKit
import SwiftUI
import UtilityCore

struct RenderedPDFPreview: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let view: PDFView

    @MainActor
    init(data: Data, filename: String) throws {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ToolError.invalid("Could not open the rendered PDF preview.")
        }
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.document = document
        view.autoScales = true
        self.data = data
        self.filename = filename
        self.view = view
    }
}

struct RenderedPDFPreviewSheet: View {
    let preview: RenderedPDFPreview
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark, category: .documents) }
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.filename)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let count = preview.view.document?.pageCount {
                        Text(count == 1 ? "1 page" : "\(count) pages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { preview.view.zoomOut(nil) }
                    .labelStyle(.iconOnly)
                Button("Fit Page", systemImage: "arrow.up.left.and.arrow.down.right") { preview.view.autoScales = true }
                    .labelStyle(.iconOnly)
                    .help("Fit page")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { preview.view.zoomIn(nil) }
                    .labelStyle(.iconOnly)
            }
            PDFReaderCanvas(view: preview.view)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel("Rendered PDF")
            if let issue {
                Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Preview…", systemImage: "square.and.arrow.up", action: save)
                    .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
            }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 620, minHeight: 390, idealHeight: 490)
        .workspaceBackground(palette)
    }

    private func save() {
        do {
            try DeveloperToolFiles.save(preview.data, as: preview.filename)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
