import PDFKit
import SwiftUI
import UtilityCore

struct PDFCropControls: View {
    let input: URL?
    @Binding var options: PDFCropOptions
    @Binding var ready: Bool
    @State private var validationIssue: String?
    @State private var document: PDFDocument?
    @State private var previewPage = 1
    @State private var dragBounds: CGRect?
    @State private var refreshID = UUID()
    @State private var anchorResetID = UUID()
    @State private var inspecting = false

    private struct PreviewRequest: Equatable {
        let input: URL?
        let refreshID: UUID
    }

    var body: some View {
        let selected = document.flatMap { try? PageSelection.indices(options.pages, pageCount: $0.pageCount) }
        VStack(alignment: .leading, spacing: 12) {
            if let document {
                PDFExportPagePicker(document: document, range: $options.pages, startsWithAll: true,
                                    anchorResetID: anchorResetID)
            } else {
                SettingRow("Pages") {
                    TextField("All pages, or e.g. 1, 3–5", text: $options.pages)
                        .accessibilityLabel("Pages to crop")
                }
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
            if input != nil {
                Button("Refresh PDF Preview", systemImage: "arrow.clockwise") {
                    ready = false
                    options.sourceStamp = nil
                    refreshID = UUID()
                }
            }
            if inspecting {
                ProgressView("Checking PDF…").controlSize(.small)
            }
            if let validationIssue, document == nil || selected != nil {
                Text(validationIssue).font(.callout).foregroundStyle(.secondary)
            }
            if let document, document.pageCount > 0 {
                let cropsPreviewPage = selected?.contains(previewPage - 1) == true
                Stepper("Preview page \(previewPage) of \(document.pageCount)", value: $previewPage, in: 1...document.pageCount)
                if document.pageCount > 1 {
                    Button("Crop Only This Page") {
                        options.pages = String(previewPage)
                        anchorResetID = UUID()
                    }
                }
                if selected != nil, !cropsPreviewPage {
                    Text("This page is outside the selected crop range.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let page = document.page(at: previewPage - 1), let reference = page.pageRef {
                    let size = PDFCrop.visibleSize(for: reference)
                    if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                        ViewThatFits(in: .horizontal) {
                            preview(page, size: size, showsCrop: cropsPreviewPage, limit: 360)
                            preview(page, size: size, showsCrop: cropsPreviewPage, limit: 245)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            Text("Cropping changes the visible area. Use Redact PDF to permanently remove content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: PreviewRequest(input: input, refreshID: refreshID)) { [refreshID] in await reload(refreshID) }
        .onChange(of: options) { _, _ in updateReadiness() }
    }

    private func updateReadiness() {
        guard let document, options.sourceStamp != nil else {
            ready = false
            return
        }
        do {
            try PDFCrop.validate(document: document, options: options)
            validationIssue = nil
            ready = true
        } catch {
            validationIssue = error.localizedDescription
            ready = false
        }
    }

    private func reload(_ requestID: UUID) async {
        guard !Task.isCancelled, requestID == refreshID else { return }
        ready = false
        options.sourceStamp = nil
        document = nil
        validationIssue = nil
        previewPage = 1
        dragBounds = nil
        inspecting = input != nil
        guard let input else { return }
        defer { if !Task.isCancelled, requestID == refreshID { inspecting = false } }
        do {
            let scan = Task.detached(priority: .userInitiated) {
                let stamp = try PDFSourceStamp.read(input)
                guard let pdf = PDFDocument(url: stamp.resolved), pdf.pageCount > 0 else {
                    throw ToolError.invalid("Could not open this PDF.")
                }
                try PDFCrop.validateSignatureFields(in: pdf)
                return stamp
            }
            let stamp = try await withTaskCancellationHandler {
                try await scan.value
            } onCancel: {
                scan.cancel()
            }
            try Task.checkCancellation()
            guard requestID == refreshID else { return }
            guard let loaded = PDFDocument(url: stamp.resolved), loaded.pageCount > 0 else {
                throw ToolError.invalid("Could not open this PDF.")
            }
            guard (try? PDFSourceStamp.read(input)) == stamp else {
                throw ToolError.invalid("This PDF changed while opening. Refresh the PDF preview.")
            }
            document = loaded
            options.sourceStamp = stamp
            updateReadiness()
        } catch {
            guard !Task.isCancelled, requestID == refreshID else { return }
            validationIssue = error.localizedDescription
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

    private func preview(_ page: PDFPage, size: CGSize, showsCrop: Bool, limit: CGFloat) -> some View {
        let scale = min(1, limit / max(size.width, size.height))
        let canvas = CGSize(width: size.width * scale, height: size.height * scale)
        let thumbnail = page.thumbnail(of: canvas, for: .cropBox)
        return Image(nsImage: thumbnail)
            .resizable()
            .frame(width: canvas.width, height: canvas.height)
            .overlay(alignment: .topLeading) {
                if showsCrop, let bounds = dragBounds ?? (try? options.offsets.displayedBounds(in: size)) {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: bounds.width * scale, height: bounds.height * scale)
                        .offset(x: bounds.minX * scale, y: bounds.minY * scale)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { gesture in
                    guard showsCrop else { return }
                    dragBounds = bounds(from: gesture, scale: scale, size: size)
                }
                .onEnded { gesture in
                    defer { dragBounds = nil }
                    guard showsCrop else { return }
                    let selection = bounds(from: gesture, scale: scale, size: size)
                    guard selection.width >= 1, selection.height >= 1 else { return }
                    var offsets = PDFCropOffsets()
                    offsets.top = selection.minY
                    offsets.right = size.width - selection.maxX
                    offsets.bottom = size.height - selection.maxY
                    offsets.left = selection.minX
                    options.offsets = offsets
                })
            .fixedSize()
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
