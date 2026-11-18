import CoreLocation
import Foundation

public struct MapCoordinate: Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw ToolError.invalid("Latitude must be −90 to 90 and longitude must be −180 to 180.")
        }
        self.latitude = latitude == 0 ? 0 : latitude
        self.longitude = longitude == 0 ? 0 : longitude
    }

    public var decimal: String {
        String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    public var degreesMinutesSeconds: String {
        Self.dms(latitude, positive: "N", negative: "S") + ", " + Self.dms(longitude, positive: "E", negative: "W")
    }

    public static func parse(_ input: String) throws -> Self {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: "−", with: "-")
        if let pair = normalized.wholeMatch(of: /([+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))\s*[,; ]\s*([+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))/),
           let latitude = Double(pair.1), let longitude = Double(pair.2) {
            return try Self(latitude: latitude, longitude: longitude)
        }
        let parts = normalized.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count == 2,
           let latitude = parseDMS(parts[0], positive: "N", negative: "S"),
           let longitude = parseDMS(parts[1], positive: "E", negative: "W") {
            return try Self(latitude: latitude, longitude: longitude)
        }
        throw ToolError.invalid("Enter latitude and longitude in decimal degrees or degrees, minutes, and seconds.")
    }

    public func distance(to other: Self) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }

    private static func parseDMS(_ input: Substring, positive: String, negative: String) -> Double? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let pieces = text.wholeMatch(of: /([0-9]{1,3})\s*°\s*([0-9]{1,2})\s*['′]\s*([0-9]{1,2}(?:\.[0-9]+)?)\s*["″]\s*([NSEW])/),
              let degrees = Double(pieces.1), let minutes = Double(pieces.2), let seconds = Double(pieces.3),
              minutes < 60, seconds < 60, pieces.4 == positive || pieces.4 == negative else { return nil }
        let magnitude = degrees + minutes / 60 + seconds / 3600
        return pieces.4 == negative ? -magnitude : magnitude
    }

    private static func dms(_ coordinate: Double, positive: String, negative: String) -> String {
        let total = Int((abs(coordinate) * 360_000).rounded())
        let degrees = total / 360_000
        let minutes = total / 6_000 % 60
        let seconds = Double(total % 6_000) / 100
        return String(format: "%d° %02d′ %05.2f″ %@", locale: Locale(identifier: "en_US_POSIX"),
                      degrees, minutes, seconds, coordinate < 0 ? negative : positive)
    }
}
