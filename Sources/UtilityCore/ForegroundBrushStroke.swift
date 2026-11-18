import CoreGraphics
import Foundation

public struct ForegroundBrushStroke: Equatable, Identifiable, Sendable {
    public static let maximumPoints = 2_048
    public static let widths = 0.005...0.25

    public let id: UUID
    /// Top-left normalized image coordinates.
    public let points: [CGPoint]
    /// Diameter as a fraction of the shorter image edge.
    public let width: Double

    public init(id: UUID = UUID(), points: [CGPoint], width: Double) {
        self.id = id
        self.points = points
        self.width = width
    }

    func paint(in context: CGContext, extent: CGRect, action: ForegroundRefinement.Action) throws {
        guard (1...Self.maximumPoints).contains(points.count), Self.widths.contains(width),
              points.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw ToolError.invalid("Invalid brush correction.")
        }

        let pixels = points.map { CGPoint(x: $0.x * extent.width, y: (1 - $0.y) * extent.height) }
        let diameter = max(1, width * min(extent.width, extent.height))
        let radius = diameter / 2
        let value: CGFloat = action == .keep ? 1 : 0
        context.setStrokeColor(gray: value, alpha: 1)
        context.setFillColor(gray: value, alpha: 1)
        if let first = pixels.first, pixels.allSatisfy({ $0 == first }) {
            context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius,
                                           width: diameter, height: diameter))
        } else {
            context.setLineWidth(diameter)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addLines(between: pixels)
            context.strokePath()
        }
        try Task.checkCancellation()
    }
}
