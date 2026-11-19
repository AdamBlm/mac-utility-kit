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
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PDF Preview").font(.headline)
                Spacer()
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { preview.view.zoomOut(nil) }
                    .labelStyle(.iconOnly)
                Button("Zoom In", systemImage: "plus.magnifyingglass") { preview.view.zoomIn(nil) }
                    .labelStyle(.iconOnly)
            }
            PDFReaderCanvas(view: preview.view)
                .accessibilityLabel("Rendered PDF")
            if let issue {
                Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Preview…", systemImage: "square.and.arrow.up", action: save)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 490)
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
