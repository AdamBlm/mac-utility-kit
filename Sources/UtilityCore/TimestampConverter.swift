import Foundation

public enum UnixTimestampUnit: String, CaseIterable, Identifiable, Sendable {
    case seconds = "Seconds"
    case milliseconds = "Milliseconds"
    case microseconds = "Microseconds"

    public var id: Self { self }

    fileprivate var decimals: Int {
        switch self {
        case .seconds: 6
        case .milliseconds: 3
        case .microseconds: 0
        }
    }

    fileprivate var microsecondsPerUnit: UInt64 {
        switch self {
        case .seconds: 1_000_000
        case .milliseconds: 1_000
        case .microseconds: 1
        }
    }
}

public struct UnixMicrosecondTimestamp: Hashable, Sendable {
    public let microseconds: Int64

    public init(microseconds: Int64) { self.microseconds = microseconds }

    public static var now: Self {
        Self(microseconds: Int64((Date.now.timeIntervalSince1970 * 1_000_000).rounded()))
    }

    public static func parse(_ input: String, unit: UnixTimestampUnit) throws -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = text.first == "-"
        let sign = negative || text.first == "+"
        let fields = text.dropFirst(sign ? 1 : 0).replacingOccurrences(of: ",", with: ".")
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(fields.count), fields.allSatisfy(isDigits), let whole = UInt64(fields[0]) else {
            throw ToolError.invalid("Enter a signed Unix timestamp using digits and an optional decimal separator.")
        }
        let fraction = fields.count == 2 ? fields[1] : ""
        guard fraction.count <= unit.decimals else {
            throw ToolError.invalid("This unit supports up to \(unit.decimals) fractional digits at microsecond precision.")
        }
        let decimal = UInt64(fraction + String(repeating: "0", count: unit.decimals - fraction.count)) ?? 0
        let (scaled, scaleOverflow) = whole.multipliedReportingOverflow(by: unit.microsecondsPerUnit)
        let (magnitude, additionOverflow) = scaled.addingReportingOverflow(decimal)
        let limit = UInt64(Int64.max) + (negative ? 1 : 0)
        guard !scaleOverflow, !additionOverflow, magnitude <= limit else {
            throw ToolError.invalid("The Unix timestamp is outside the supported 64-bit range.")
        }
        if negative, magnitude > UInt64(Int64.max) { return Self(microseconds: .min) }
        let value = Int64(magnitude)
        return Self(microseconds: negative ? -value : value)
    }

    public func formatted(in unit: UnixTimestampUnit) -> String {
        let divisor = unit.microsecondsPerUnit
        let (whole, remainder) = microseconds.magnitude.quotientAndRemainder(dividingBy: divisor)
        let sign = microseconds < 0 ? "-" : ""
        guard remainder > 0 else { return sign + String(whole) }
        let digits = String(remainder)
        let padding = String(repeating: "0", count: unit.decimals - digits.count)
        let fraction = (padding + digits).reversed().drop(while: { $0 == "0" }).reversed()
        return sign + String(whole) + "." + String(fraction)
    }

    fileprivate var split: (seconds: Int64, fraction: Int64) {
        let (whole, remainder) = microseconds.quotientAndRemainder(dividingBy: 1_000_000)
        if remainder < 0 { return (whole - 1, remainder + 1_000_000) }
        return (whole, remainder)
    }

    private static func isDigits(_ field: Substring) -> Bool {
        !field.isEmpty && field.utf8.allSatisfy { (48...57).contains($0) }
    }
}

public struct TimestampDisplay: Equatable, Sendable {
    public let local: String
    public let iso8601: String
    public let offset: String
}

public struct LocalTimestampMatch: Equatable, Identifiable, Sendable {
    public let timestamp: UnixMicrosecondTimestamp
    public let offset: String

    public var id: UnixMicrosecondTimestamp { timestamp }
}

public enum TimestampConverter {
    private static let minimumCivilSecond: Int64 = -62_135_596_800
    private static let maximumCivilSecond: Int64 = 253_402_300_799

    /// Resolves a local date using the selected zone, or an ISO 8601 date using its explicit offset.
    public static func resolveDate(_ input: String, in zone: TimeZone) throws -> [LocalTimestampMatch] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = text.wholeMatch(of: /(.+?)([Zz]|[+-][0-9]{2}:[0-9]{2}| UTC[+-][0-9]{2}:[0-9]{2}(?::[0-9]{2})?)/) else {
            return try resolveLocal(text, in: zone)
        }
        let (nominal, micros) = try civilDate(String(parts.1))
        // RFC 3339 defines numeric offsets as local time minus UTC.
        let numeric = parts.2.hasPrefix(" UTC") ? parts.2.dropFirst(4) : parts.2
        let offset: Int
        if numeric == "Z" || numeric == "z" {
            offset = 0
        } else {
            let fields = numeric.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard (2...3).contains(fields.count), fields[0] < 24, fields.dropFirst().allSatisfy({ $0 < 60 }) else {
                throw ToolError.invalid("Enter a valid offset in Z, ±HH:MM, or UTC±HH:MM[:SS] format.")
            }
            let magnitude = fields[0] * 3_600 + fields[1] * 60 + (fields.count == 3 ? fields[2] : 0)
            offset = numeric.first == "-" ? -magnitude : magnitude
        }
        let seconds = Int64(nominal.timeIntervalSince1970.rounded()) - Int64(offset)
        guard (minimumCivilSecond...maximumCivilSecond).contains(seconds) else {
            throw ToolError.invalid("This offset places the timestamp outside Gregorian years 0001 to 9999.")
        }
        let label = numeric == "-00:00" ? "Unknown local offset (UTC−00:00)" : offsetLabel(offset)
        return [LocalTimestampMatch(timestamp: .init(microseconds: seconds * 1_000_000 + micros), offset: label)]
    }

    /// Returns zero matches in a gap and all valid instants in a repeated wall-clock interval.
    public static func resolveLocal(_ input: String, in zone: TimeZone) throws -> [LocalTimestampMatch] {
        let (nominal, micros) = try civilDate(input)
        let matches: [LocalTimestampMatch] = nearbyOffsets(in: zone, around: nominal).compactMap { offset in
            let candidate = nominal.addingTimeInterval(-Double(offset))
            guard zone.secondsFromGMT(for: candidate) == offset else { return nil }
            let seconds = Int64(candidate.timeIntervalSince1970.rounded())
            let stamp = UnixMicrosecondTimestamp(microseconds: seconds * 1_000_000 + micros)
            return LocalTimestampMatch(timestamp: stamp, offset: offsetLabel(offset))
        }.sorted { $0.timestamp.microseconds < $1.timestamp.microseconds }
        let representable = matches.filter {
            (minimumCivilSecond...maximumCivilSecond).contains($0.timestamp.split.seconds)
        }
        if !matches.isEmpty, representable.isEmpty {
            throw ToolError.invalid("The selected time zone places this timestamp outside Gregorian years 0001 to 9999.")
        }
        return representable
    }

    private static func civilDate(_ input: String) throws -> (Date, Int64) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = text.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})[ Tt]([0-9]{2}):([0-9]{2}):([0-5][0-9])(?:[.,]([0-9]{1,6}))?/),
              parts.1 != "0000" else {
            throw ToolError.invalid("Enter YYYY-MM-DD HH:MM:SS with up to six fractional digits.")
        }
        let canonical = "\(parts.1)-\(parts.2)-\(parts.3) \(parts.4):\(parts.5):\(parts.6)"
        let formatter = civilFormatter()
        guard let nominal = formatter.date(from: canonical), formatter.string(from: nominal) == canonical else {
            throw ToolError.invalid("Enter a valid Gregorian date and time.")
        }
        let fraction = parts.7.map { String($0) } ?? ""
        let micros = Int64(fraction + String(repeating: "0", count: 6 - fraction.count)) ?? 0
        return (nominal, micros)
    }

    public static func display(_ timestamp: UnixMicrosecondTimestamp, in zone: TimeZone) throws -> TimestampDisplay {
        let (seconds, fraction) = timestamp.split
        guard (minimumCivilSecond...maximumCivilSecond).contains(seconds) else {
            throw ToolError.invalid("The timestamp is outside Gregorian years 0001 to 9999.")
        }
        let date = Date(timeIntervalSince1970: Double(seconds))
        let offset = zone.secondsFromGMT(for: date)
        let localSecond = seconds + Int64(offset)
        guard (minimumCivilSecond...maximumCivilSecond).contains(localSecond) else {
            throw ToolError.invalid("The selected time zone places this timestamp outside Gregorian years 0001 to 9999.")
        }
        let formatter = civilFormatter()
        let utc = formatter.string(from: date).replacingOccurrences(of: " ", with: "T")
        let civil = formatter.string(from: Date(timeIntervalSince1970: Double(localSecond)))
        let subsecond = String(format: ".%06d", Int(fraction))
        return TimestampDisplay(local: civil + subsecond, iso8601: utc + subsecond + "Z", offset: offsetLabel(offset))
    }

    private static func nearbyOffsets(in zone: TimeZone, around nominal: Date) -> Set<Int> {
        // A nominal UTC wall time is within one day of all IANA zone candidates.
        // Offset changes can be shorter than one hour, or be political rather than seasonal.
        let before = nominal.addingTimeInterval(-172_800)
        let after = nominal.addingTimeInterval(172_800)
        var offsets = Set([before, nominal, after].map { zone.secondsFromGMT(for: $0) })
        var cursor = before
        while let transition = zone.nextDaylightSavingTimeTransition(after: cursor),
              transition > cursor, transition <= after {
            offsets.insert(zone.secondsFromGMT(for: transition.addingTimeInterval(-1)))
            offsets.insert(zone.secondsFromGMT(for: transition))
            cursor = transition
        }
        return offsets
    }

    private static func civilFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.gregorianStartDate = Date(timeIntervalSince1970: -100_000_000_000)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }

    private static func offsetLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        let base = String(format: "UTC%@%02d:%02d", sign, total / 3600, total / 60 % 60)
        return total.isMultiple(of: 60) ? base : base + String(format: ":%02d", total % 60)
    }
}
