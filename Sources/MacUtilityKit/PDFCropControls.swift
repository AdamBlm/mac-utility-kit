import PDFKit
import SwiftUI
import UtilityCore

struct PDFCropControls: View {
    let input: URL?
    @Binding var options: PDFCropOptions
    @State private var document: PDFDocument?
    @State private var previewPage = 1
    @State private var dragBounds: CGRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Pages") {
                TextField("All pages, or e.g. 1, 3–5", text: $options.pages)
                    .accessibilityLabel("Pages to crop")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    offset("Top", value: $options.offsets.top)
                    offset("Right", value: $options.offsets.right)
                }
                GridRow {
                    offset("Bottom", value: $options.offsets.bottom)
                    offset("Left", value: $options.offsets.left)
                }
            }
            Button("Reset offsets") { options.offsets = PDFCropOffsets() }
            if let document, document.pageCount > 0 {
                Stepper("Preview page \(previewPage) of \(document.pageCount)", value: $previewPage, in: 1...document.pageCount)
                if let page = document.page(at: previewPage - 1), let reference = page.pageRef {
                    preview(page, size: PDFSigning.visibleSize(for: reference))
                }
            }
            Text("Cropping changes the visible area. Use Redact PDF to permanently remove content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: input) {
            document = input.flatMap { PDFDocument(url: $0) }
            previewPage = 1
        }
    }

    private func offset(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            TextField(label, value: value, format: .number)
                .labelsHidden()
                .accessibilityLabel("\(label) crop in points")
            Text("pt").foregroundStyle(.secondary)
        }
    }

    private func preview(_ page: PDFPage, size: CGSize) -> some View {
        let scale = min(1, 280 / max(1, max(size.width, size.height)))
        let canvas = CGSize(width: size.width * scale, height: size.height * scale)
        let thumbnail = page.thumbnail(of: canvas, for: .cropBox)
        return Image(nsImage: thumbnail)
            .resizable()
            .frame(width: canvas.width, height: canvas.height)
            .overlay(alignment: .topLeading) {
                if let bounds = dragBounds ?? (try? options.offsets.displayedBounds(in: size)) {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: bounds.width * scale, height: bounds.height * scale)
                        .offset(x: bounds.minX * scale, y: bounds.minY * scale)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { gesture in
                    dragBounds = bounds(from: gesture, scale: scale, size: size)
                }
                .onEnded { gesture in
                    defer { dragBounds = nil }
                    let selection = bounds(from: gesture, scale: scale, size: size)
                    guard selection.width >= 1, selection.height >= 1 else { return }
                    var offsets = PDFCropOffsets()
                    offsets.top = selection.minY
                    offsets.right = size.width - selection.maxX
                    offsets.bottom = size.height - selection.maxY
                    offsets.left = selection.minX
                    options.offsets = offsets
                })
            .accessibilityLabel("Crop preview for page \(previewPage)")
    }

    private func bounds(from gesture: DragGesture.Value, scale: CGFloat, size: CGSize) -> CGRect {
        let start = CGPoint(
            x: min(size.width, max(0, gesture.startLocation.x / scale)),
            y: min(size.height, max(0, gesture.startLocation.y / scale))
        )
        let end = CGPoint(
            x: min(size.width, max(0, gesture.location.x / scale)),
            y: min(size.height, max(0, gesture.location.y / scale))
        )
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(start.x - end.x), height: abs(start.y - end.y))
    }
}
