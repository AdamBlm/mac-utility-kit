import SwiftUI
import UtilityCore

struct ScreenshotAnnotationCanvas: View {
    let image: CGImage
    @Binding var draft: AnnotateScreenshotDraft
    let selectionColor: Color
    @State private var drag: Drag?

    private struct Drag {
        let original: ScreenshotAnnotation?
        let startsNewLayer: Bool
        var live: ScreenshotAnnotation?
    }

    var body: some View {
        GeometryReader { geometry in
            let size = canvasSize(availableWidth: geometry.size.width)
            if draft.zoom == 0 {
                artwork(size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    artwork(size: size)
                }
            }
        }
        .frame(height: 340)
        .onChange(of: draft.activeTool) { drag = nil }
    }

    private func artwork(size: CGSize) -> some View {
        let scale = size.width / CGFloat(image.width)
        return ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
            Canvas { graphics, size in
                graphics.withCGContext { context in
                    context.saveGState()
                    context.translateBy(x: 0, y: size.height)
                    context.scaleBy(x: 1, y: -1)
                    ScreenshotAnnotationRenderer.draw(liveLayers, in: context, size: size, displayScale: scale)
                    context.restoreGState()
                }
                if let selected = selectedLayer {
                    let rect = ScreenshotAnnotationRenderer.bounds(for: selected, size: size, displayScale: scale)
                        .insetBy(dx: -3, dy: -3)
                    graphics.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(selectionColor),
                                    style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                }
            }
            .frame(width: size.width, height: size.height)
            .accessibilityLabel("Screenshot annotation canvas")
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { update($0, size: size, scale: scale) }
            .onEnded { finish($0, size: size, scale: scale) })
    }

    private var liveLayers: [ScreenshotAnnotation] {
        guard let drag, let live = drag.live else { return draft.history.layers }
        if drag.startsNewLayer { return draft.history.layers + [live] }
        return draft.history.layers.map { $0.id == live.id ? live : $0 }
    }

    private var selectedLayer: ScreenshotAnnotation? {
        guard draft.activeTool == nil, let selected = draft.selected else { return nil }
        return liveLayers.first { $0.id == selected }
    }

    private func canvasSize(availableWidth: CGFloat) -> CGSize {
        let scale = draft.zoom > 0 ? draft.zoom :
            max(0.001, min(availableWidth / CGFloat(image.width), 340 / CGFloat(image.height)))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
    }

    private func update(_ value: DragGesture.Value, size: CGSize, scale: Double) {
        if drag == nil { begin(value.startLocation, size: size, scale: scale) }
        guard let original = drag?.original else { return }
        let point = normalized(value.location, size: size)
        if drag?.startsNewLayer == true {
            var current = original
            if !current.kind.isPoint { current.end = point }
            drag?.live = current
        } else {
            let start = normalized(value.startLocation, size: size)
            drag?.live = original.moved(by: CGPoint(x: point.x - start.x, y: point.y - start.y))
        }
    }

    private func begin(_ location: CGPoint, size: CGSize, scale: Double) {
        let point = normalized(location, size: size)
        if let tool = draft.activeTool, draft.history.canAdd {
            guard tool != .text || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let number = min(999, (draft.history.layers.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1)
            let item = ScreenshotAnnotation(kind: tool, start: point, end: point, color: draft.color,
                                            stroke: draft.stroke, fontSize: draft.fontSize, text: draft.text, number: number)
            drag = Drag(original: item, startsNewLayer: true, live: item)
        } else if draft.activeTool == nil {
            let item = draft.history.layers.reversed().first {
                ScreenshotAnnotationRenderer.hits($0, point: location, size: size, displayScale: scale)
            }
            draft.selected = item?.id
            drag = Drag(original: item, startsNewLayer: false, live: item)
        }
    }

    private func finish(_ value: DragGesture.Value, size: CGSize, scale: Double) {
        defer { drag = nil }
        update(value, size: size, scale: scale)
        guard let drag, let live = drag.live else { return }
        if drag.startsNewLayer {
            let w = abs(live.end.x - live.start.x) * size.width
            let h = abs(live.end.y - live.start.y) * size.height
            if live.kind == .box || live.kind == .oval {
                guard min(w, h) >= 3 else { return }
            } else if !live.kind.isPoint {
                guard hypot(w, h) >= 3 else { return }
            }
            draft.history.add(live)
        } else {
            draft.history.replace(live)
        }
    }
}
