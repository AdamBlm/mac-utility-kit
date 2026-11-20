import Foundation

public enum UUIDGenerator {
    public enum Version: Int, CaseIterable, Identifiable, Sendable {
        case random = 4
        case timestamped = 7

        public var id: Int { rawValue }
    }

    public struct Inspection: Equatable, Sendable {
        public let canonicalUUID: String
        public let version: Int?
        public let variant: String
        public let unixMilliseconds: UInt64?
        public var urn: String { "urn:uuid:" + canonicalUUID }

        public var date: Date? {
            unixMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }
    }

    public static func generate(
        _ version: Version, count: Int, uppercase: Bool = false, hyphenated: Bool = true, now: Date = .now
    ) throws -> [String] {
        guard (1...10_000).contains(count) else {
            throw ToolError.invalid("Choose between 1 and 10,000 UUIDs.")
        }
        let milliseconds = (now.timeIntervalSince1970 * 1000).rounded(.down)
        guard version == .random || (milliseconds.isFinite && milliseconds >= 0 && milliseconds < 281_474_976_710_656) else {
            throw ToolError.invalid("The date is outside the UUID v7 timestamp range.")
        }
        var random = SystemRandomNumberGenerator()
        return (0..<count).map { _ in
            let uuid: UUID
            switch version {
            case .random:
                uuid = UUID()
            case .timestamped:
                uuid = timestamped(milliseconds: UInt64(milliseconds), random: &random)
            }
            let text = uppercase ? uuid.uuidString : uuid.uuidString.lowercased()
            return hyphenated ? text : text.replacingOccurrences(of: "-", with: "")
        }
    }

    public static func inspect(_ input: String) throws -> Inspection {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical: String
        if text.prefix(9).lowercased() == "urn:uuid:" {
            canonical = String(text.dropFirst(9))
        } else if text.utf8.count == 32, text.utf8.allSatisfy(isHexDigit) {
            let characters = Array(text)
            canonical = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(characters[$0]) }.joined(separator: "-")
        } else {
            canonical = text
        }
        let canonicalBytes = canonical.utf8
        guard canonicalBytes.count == 36,
              canonicalBytes.enumerated().allSatisfy({ index, byte in
                  [8, 13, 18, 23].contains(index) ? byte == 45 : isHexDigit(byte)
              }),
              let uuid = UUID(uuidString: canonical) else {
            throw ToolError.invalid("Enter a UUID with 32 hex digits or a urn:uuid: identifier with standard hyphens.")
        }
        let value = uuid.uuidString.lowercased()
        let bytes = uuid.uuid
        let variant = bytes.8
        guard variant & 0xC0 == 0x80 else {
            let name: String
            if variant & 0x80 == 0 { name = "NCS" }
            else if variant & 0xE0 == 0xC0 { name = "Microsoft" }
            else { name = "Reserved" }
            return Inspection(canonicalUUID: value, version: nil, variant: name, unixMilliseconds: nil)
        }
        let version = Int(bytes.6 >> 4)
        let timestamp = version == 7
            ? [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            : nil
        return Inspection(canonicalUUID: value, version: version, variant: "RFC 9562", unixMilliseconds: timestamp)
    }

    private static func timestamped(milliseconds: UInt64, random: inout SystemRandomNumberGenerator) -> UUID {
        let bytes = stride(from: 40, through: 0, by: -8).map { UInt8(truncatingIfNeeded: milliseconds >> $0) }
        let entropy = (0..<10).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            0x70 | (entropy[0] & 0x0F), entropy[1], 0x80 | (entropy[2] & 0x3F),
            entropy[3], entropy[4], entropy[5], entropy[6], entropy[7], entropy[8], entropy[9]
        ))
    }

    private static func isHexDigit(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
    }
}
