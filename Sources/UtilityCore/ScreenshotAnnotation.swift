import CoreGraphics
import Foundation

public enum ScreenshotAnnotationKind: String, CaseIterable, Identifiable, Sendable {
    case arrow = "Arrow"
    case line = "Line"
    case box = "Box"
    case oval = "Oval"
    case text = "Text"
    case number = "Numbered callout"

    public var id: Self { self }
    public var isPoint: Bool { self == .text || self == .number }
}

public struct ScreenshotAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: ScreenshotAnnotationKind
    /// Points are normalized to the original image with the origin at the top left.
    public var start: CGPoint
    public var end: CGPoint
    public var color: UInt32
    public var stroke: Double
    public var fontSize: Double
    public var text: String
    public var number: Int

    public init(kind: ScreenshotAnnotationKind, start: CGPoint, end: CGPoint,
                color: UInt32 = 0xFF595E, stroke: Double = 8,
                fontSize: Double = 40, text: String = "", number: Int = 1, id: UUID = UUID()) {
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.stroke = stroke
        self.fontSize = fontSize
        self.text = text
        self.number = number
        self.id = id
    }

    public func moved(by delta: CGPoint) -> Self {
        var result = self
        let dx = min(1 - max(start.x, end.x), max(-min(start.x, end.x), delta.x))
        let dy = min(1 - max(start.y, end.y), max(-min(start.y, end.y), delta.y))
        result.start = CGPoint(x: start.x + dx, y: start.y + dy)
        result.end = CGPoint(x: end.x + dx, y: end.y + dy)
        return result
    }
}

public struct ScreenshotAnnotationHistory: Sendable {
    public private(set) var layers: [ScreenshotAnnotation] = []
    private var past: [[ScreenshotAnnotation]] = []
    private var future: [[ScreenshotAnnotation]] = []

    public init() {}
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var canAdd: Bool { layers.count < 200 }

    public mutating func add(_ layer: ScreenshotAnnotation) {
        guard canAdd else { return }
        commit(layers + [layer])
    }

    public mutating func replace(_ layer: ScreenshotAnnotation) {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        var next = layers
        next[index] = layer
        commit(next)
    }

    public mutating func remove(_ id: UUID) { commit(layers.filter { $0.id != id }) }

    public mutating func move(_ id: UUID, by offset: Int) {
        guard let index = layers.firstIndex(where: { $0.id == id }),
              offset >= -index, offset < layers.count - index else { return }
        var next = layers
        let layer = next.remove(at: index)
        next.insert(layer, at: index + offset)
        commit(next)
    }

    public mutating func undo() {
        guard let state = past.popLast() else { return }
        future.append(layers)
        layers = state
    }

    public mutating func redo() {
        guard let state = future.popLast() else { return }
        past.append(layers)
        layers = state
    }

    private mutating func commit(_ next: [ScreenshotAnnotation]) {
        guard next != layers else { return }
        past.append(layers)
        if past.count > 64 { past.removeFirst() }
        layers = next
        future.removeAll()
    }
}
