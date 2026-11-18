import AppKit
import Observation
import PDFKit
import SwiftUI
import UtilityCore

@MainActor
@Observable
final class PDFRedactionPreviewSession {
    let view = PDFView()
    private(set) var pageNumber = 1
    private(set) var hasSelection = false
    @ObservationIgnored private var overlays: [PDFAnnotation] = []

    init() {
        view.displayMode = .singlePage
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
    }

    func open(_ source: PDFRedactionSource?) {
        overlays = []
        pageNumber = 1
        hasSelection = false
        let document = source.flatMap { PDFDocument(data: $0.data) }
        view.document = document
        view.autoScales = true
        if let document {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations { page.removeAnnotation(annotation) }
            }
        }
    }

    func navigate(_ pageNumber: Int) {
        guard pageNumber > 0, let page = view.document?.page(at: pageNumber - 1) else { return }
        view.go(to: page)
        synchronize()
    }

    func synchronize() {
        if let page = view.currentPage, let document = view.document {
            let number = document.index(for: page) + 1
            if (1...document.pageCount).contains(number) { pageNumber = number }
        }
        hasSelection = view.currentSelection?.string?.isEmpty == false
    }

    func selectedMarks() -> [PDFRedactionMark] {
        guard let selection = view.currentSelection, let document = view.document else { return [] }
        let marks = PDFRedaction.marks(for: selection, in: document)
        view.clearSelection()
        synchronize()
        return marks
    }

    func mark(drag: CGRect) -> PDFRedactionMark? {
        guard let document = view.document, let page = view.currentPage else { return nil }
        let area = view.isFlipped ? drag : CGRect(x: drag.minX, y: view.bounds.height - drag.maxY,
                                                  width: drag.width, height: drag.height)
        let pageFrame = view.convert(page.bounds(for: .cropBox), from: page)
        let clipped = area.intersection(pageFrame)
        guard clipped.width > 4, clipped.height > 4,
              let geometry = try? PDFRedactionGeometry(page),
              let normalized = geometry.normalized(view.convert(clipped, to: page)) else { return nil }
        return PDFRedactionMark(page: document.index(for: page) + 1, rect: normalized, kind: .region)
    }

    func show(_ marks: [PDFRedactionMark], fill: PDFRedactionFill, focused: UUID?) {
        for overlay in overlays { overlay.page?.removeAnnotation(overlay) }
        overlays = []
        let color: NSColor = fill == .black ? .black : .white
        for mark in marks where mark.page == pageNumber {
            guard let page = view.document?.page(at: mark.page - 1),
                  let geometry = try? PDFRedactionGeometry(page),
                  let bounds = geometry.pageRect(mark.rect) else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = mark.id == focused ? 2 : 0.5
            annotation.border = border
            annotation.color = mark.id == focused ? .systemRed : .systemGray
            annotation.interiorColor = color
            annotation.shouldPrint = false
            page.addAnnotation(annotation)
            overlays.append(annotation)
        }
    }
}

struct PDFRedactionPreview: View {
    let session: PDFRedactionPreviewSession
    let drawsRectangles: Bool
    let onMark: (PDFRedactionMark) -> Void
    @State private var drag: CGRect?

    var body: some View {
        PDFRedactionNativeView(session: session)
            .overlay(alignment: .topLeading) {
                if drawsRectangles {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .local)
                            .onChanged { value in drag = area(value) }
                            .onEnded { value in
                                if let mark = session.mark(drag: area(value)) { onMark(mark) }
                                drag = nil
                            })
                        .accessibilityHidden(true)
                    if let drag {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.27))
                            .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1) }
                            .frame(width: drag.width, height: drag.height)
                            .offset(x: drag.minX, y: drag.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onChange(of: drawsRectangles) { drag = nil }
    }

    private func area(_ value: DragGesture.Value) -> CGRect {
        CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
               width: abs(value.translation.width), height: abs(value.translation.height))
    }
}

private struct PDFRedactionNativeView: NSViewRepresentable {
    let session: PDFRedactionPreviewSession
    func makeNSView(context: Context) -> PDFView { session.view }
    func updateNSView(_ view: PDFView, context: Context) {}
}
