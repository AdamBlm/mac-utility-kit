import SwiftUI
import UtilityCore

struct ForegroundBrushCanvas: View {
    let image: CGImage
    let overlay: CGImage?
    let refinements: [ForegroundRefinement]
    let action: ForegroundRefinement.Action
    let width: Double
    let enabled: Bool
    let onStroke: (ForegroundBrushStroke, ForegroundRefinement.Action) -> Void

    @State private var points: [CGPoint] = []

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                picture(image, size: geometry.size).opacity(overlay == nil ? 1 : 0.35)
                if let overlay { picture(overlay, size: geometry.size) }
                Canvas { context, size in
                    for refinement in refinements {
                        if case .brush(let stroke) = refinement.shape {
                            mark(stroke.points, width: stroke.width, action: refinement.action, in: context, size: size, opacity: 0.28)
                        }
                    }
                    mark(points, width: width, action: action, in: context, size: size, opacity: 0.65)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    if enabled { sample(event.location, size: geometry.size) }
                }
                .onEnded { event in
                    guard enabled else { points = []; return }
                    sample(event.location, size: geometry.size)
                    let stroke = ForegroundBrushStroke(points: points, width: width)
                    points = []
                    if !stroke.points.isEmpty { onStroke(stroke, action) }
                })
            .clipped()
            .accessibilityLabel("Brush corrections on the foreground mask")
        }
    }

    private func picture(_ source: CGImage, size: CGSize) -> some View {
        Image(decorative: source, scale: 1)
            .resizable()
            .interpolation(.none)
            .frame(width: size.width, height: size.height)
    }

    private func sample(_ location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0, points.count < ForegroundBrushStroke.maximumPoints else { return }
        let point = CGPoint(x: min(1, max(0, location.x / size.width)),
                            y: min(1, max(0, location.y / size.height)))
        guard points.last != point else { return }
        points.append(point)
    }

    private func mark(
        _ points: [CGPoint], width: Double, action: ForegroundRefinement.Action,
        in context: GraphicsContext, size: CGSize, opacity: Double
    ) {
        guard let first = points.first else { return }
        let start = CGPoint(x: first.x * size.width, y: first.y * size.height)
        let diameter = max(1, width * min(size.width, size.height))
        let color: Color = (action == .keep ? Color.green : Color.orange).opacity(opacity)
        if points.count == 1 {
            context.fill(Path(ellipseIn: CGRect(x: start.x - diameter / 2, y: start.y - diameter / 2,
                                                width: diameter, height: diameter)), with: .color(color))
        } else {
            var path = Path()
            path.move(to: start)
            path.addLines(points.dropFirst().map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: diameter, lineCap: .round, lineJoin: .round))
        }
    }
}
