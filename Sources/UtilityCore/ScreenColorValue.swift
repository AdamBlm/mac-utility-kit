import Foundation

public enum ScreenColorFormat: String, CaseIterable, Identifiable, Sendable {
    case hex = "HEX"
    case rgb = "RGB"
    case hsl = "HSL"

    public var id: Self { self }
}

public enum ScreenColorPrecision: Int, CaseIterable, Identifiable, Sendable {
    case whole = 0, tenths = 1, hundredths = 2, thousandths = 3

    public var id: Self { self }
}

public struct ScreenColorValue: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init?(red: Double, green: Double, blue: Double) {
        guard red.isFinite, green.isFinite, blue.isFinite else { return nil }
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let chroma = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard chroma > 0 else { return (0, 0, lightness) }
        let denominator = lightness <= 0.5 ? (maximum + minimum) : (1 - maximum) + (1 - minimum)
        let saturation = denominator > 0 ? min(1, chroma / denominator) : 0
        let sector: Double
        if maximum == red {
            sector = (green - blue) / chroma
        } else if maximum == green {
            sector = (blue - red) / chroma + 2
        } else {
            sector = (red - green) / chroma + 4
        }
        let degrees = sector * 60
        let normalized = degrees < 0 ? degrees + 360 : degrees
        return (normalized == 360 ? 0 : normalized, saturation, lightness)
    }

    public func value(_ format: ScreenColorFormat, precision: ScreenColorPrecision = .whole) -> String {
        func decimal(_ number: Double) -> String {
            if precision == .whole { return String(Int(number.rounded())) }
            return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), precision.rawValue, number)
        }
        switch format {
        case .hex:
            let bytes = [red, green, blue].map { UInt32(($0 * 255).rounded()) }
            return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
        case .rgb:
            return "rgb(\(decimal(red * 255)), \(decimal(green * 255)), \(decimal(blue * 255)))"
        case .hsl:
            let color = hsl
            let rounded = decimal(color.hue)
            let hue = Double(rounded) == 360 ? decimal(0) : rounded
            return "hsl(\(hue), \(decimal(color.saturation * 100))%, \(decimal(color.lightness * 100))%)"
        }
    }
}

public struct ColorSampleHistory: Sendable {
    public private(set) var current: ScreenColorValue?
    public private(set) var recent: [ScreenColorValue] = []

    public init() {}

    public mutating func sample(_ color: ScreenColorValue) {
        current = color
        recent.removeAll { $0 == color }
        recent.insert(color, at: 0)
        if recent.count > 16 { recent.removeLast() }
    }

    public mutating func select(_ color: ScreenColorValue) {
        if recent.contains(color) { current = color }
    }

    public mutating func clear() {
        current = nil
        recent.removeAll()
    }
}
