import PDFKit
import SwiftUI

extension View {
    func pdfPagePreview(_ page: PDFPage?, number: Int, quarterTurns: Int = 0) -> some View {
        modifier(PDFPagePreviewButton(page: page, number: number, quarterTurns: quarterTurns))
    }
}

private struct PDFPagePreviewButton: ViewModifier {
    let page: PDFPage?
    let number: Int
    let quarterTurns: Int
    @State private var preview: PDFDocument?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if let page {
                    Button("Preview page \(number)", systemImage: "magnifyingglass") {
                        guard let copy = page.copy() as? PDFPage else { return }
                        copy.rotation = ((copy.rotation % 360 + quarterTurns * 90) % 360 + 360) % 360
                        let document = PDFDocument()
                        document.insert(copy, at: 0)
                        preview = document
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(5)
                    .background(.regularMaterial, in: .rect(cornerRadius: 5))
                    .padding(3)
                    .help("Preview page \(number)")
                }
            }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let preview {
                    PDFPagePreviewSheet(document: preview, number: number)
                }
            }
    }
}

private struct PDFPagePreviewSheet: View {
    let document: PDFDocument
    let number: Int
    @Environment(\.dismiss) private var dismiss
    @State private var view = PDFView()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Page \(number)").font(.headline)
                Spacer()
                Button("Zoom out", systemImage: "minus.magnifyingglass") { view.zoomOut(nil) }
                Button("Fit page", systemImage: "arrow.up.left.and.arrow.down.right") { view.autoScales = true }
                Button("Zoom in", systemImage: "plus.magnifyingglass") { view.zoomIn(nil) }
                Divider().frame(height: 16)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .labelStyle(.iconOnly)
            .padding(12)
            Divider()
            PDFReaderCanvas(view: view)
        }
        .frame(minWidth: 460, idealWidth: 660, minHeight: 400, idealHeight: 620)
        .onAppear {
            view.displayMode = .singlePage
            view.displayBox = .cropBox
            view.document = document
            view.autoScales = true
        }
    }
}
