public enum DeadPixelColor: String, CaseIterable, Sendable {
    case black, white, red, green, blue
}

public struct DeadPixelSequence: Sendable {
    private var index: Int
    public var color: DeadPixelColor { DeadPixelColor.allCases[index] }

    public init(startingAt color: DeadPixelColor = .black) {
        index = DeadPixelColor.allCases.firstIndex(of: color) ?? 0
    }

    public mutating func select(number: Int) -> Bool {
        guard (1...DeadPixelColor.allCases.count).contains(number) else { return false }
        index = number - 1
        return true
    }

    public mutating func step(_ direction: Int) {
        let count = DeadPixelColor.allCases.count
        index = (index + direction % count + count) % count
    }
}

package enum DeadPixelTargetStatus: Equatable, Sendable {
    case available, disconnected, mirrored

    package init(connected: Bool, mirrored: Bool) {
        if !connected { self = .disconnected }
        else { self = mirrored ? .mirrored : .available }
    }
}
