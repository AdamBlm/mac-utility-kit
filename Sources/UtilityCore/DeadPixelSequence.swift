public enum DeadPixelColor: String, CaseIterable, Sendable {
    case black, white, red, green, blue
}

public struct DeadPixelSequence: Sendable {
    private var index = 0
    public var color: DeadPixelColor { DeadPixelColor.allCases[index] }

    public init() {}

    public mutating func step(_ direction: Int) {
        let count = DeadPixelColor.allCases.count
        index = (index + direction % count + count) % count
    }
}
