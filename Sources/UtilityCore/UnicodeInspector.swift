import Foundation

public enum UnicodeInspector {
    public static let maximumFileBytes = 1_048_576

    public static func loadUTF8(_ file: URL) async throws -> String {
        try Task.checkCancellation()
        guard file.isFileURL else { throw ToolError.invalid("Choose a local UTF-8 file.") }
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true else { throw ToolError.invalid("Choose a local UTF-8 file.") }
        let sizeIssue = ToolError.invalid("Choose a UTF-8 file no larger than 1 MiB.")
        if let size = attributes.fileSize, size > maximumFileBytes { throw sizeIssue }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        try Task.checkCancellation()
        guard bytes.count <= maximumFileBytes else { throw sizeIssue }
        // Keep every scalar, including U+FEFF and NUL, so inspection matches the file bytes.
        guard let text = String(validating: bytes, as: UTF8.self) else {
            throw ToolError.invalid("This file contains invalid UTF-8.")
        }
        return text
    }

    public enum Normalization: String, CaseIterable, Sendable {
        case nfc = "NFC"
        case nfd = "NFD"

        public func apply(to text: String) -> String {
            switch self {
            case .nfc: text.precomposedStringWithCanonicalMapping
            case .nfd: text.decomposedStringWithCanonicalMapping
            }
        }
    }

    public struct Scalar: Sendable {
        public let value: Unicode.Scalar

        public init(value: Unicode.Scalar) { self.value = value }

        public var codePoint: String { String(format: "U+%04X", value.value) }
        public var name: String { value.properties.name ?? value.properties.nameAlias ?? "Unnamed" }
        public var category: String { String(describing: value.properties.generalCategory) }
        public var utf8: String { UnicodeInspector.hex(String(value).utf8) }

        public var invisibleMarker: String? {
            switch value {
            case "\r": return "CR"
            case "\n": return "LF"
            case "\t": return "TAB"
            case " ": return "SPACE"
            case "\u{0000}": return "NUL"
            case "\u{FEFF}": return "BOM / ZWNBSP"
            default: break
            }
            let properties = value.properties
            if properties.isBidiControl { return "BIDI CONTROL" }
            if properties.isJoinControl { return "JOIN CONTROL" }
            if properties.isVariationSelector { return "VARIATION SELECTOR" }
            if properties.isWhitespace { return "WHITESPACE" }
            if properties.isDefaultIgnorableCodePoint { return "DEFAULT IGNORABLE" }
            if properties.generalCategory == .control { return "CONTROL" }
            if properties.generalCategory == .format { return "FORMAT" }
            return nil
        }

        public var display: String {
            if let invisibleMarker { return "[\(invisibleMarker)]" }
            switch value.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                return "◌\(value)"
            default:
                return String(value)
            }
        }
    }

    public struct Grapheme: Sendable {
        public let value: Character

        public init(value: Character) { self.value = value }

        public var scalars: [Scalar] { value.unicodeScalars.map(Scalar.init(value:)) }
        public var utf8: String { UnicodeInspector.hex(String(value).utf8) }
        public var display: String {
            let units = scalars
            if units.allSatisfy({ $0.invisibleMarker != nil }) || units.count == 1 {
                return units.map(\.display).joined()
            }
            return String(value)
        }
    }

    public static let confusablesVersion = "18.0.0"

    // UTS #39 confusables.txt maps a single scalar to one or more prototype scalars.
    public static let confusables: [Unicode.Scalar: String]? = {
        let url = Bundle.main.url(forResource: "confusables", withExtension: "txt")
            ?? Bundle.module.url(forResource: "confusables", withExtension: "txt")
        guard let url, let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var mapping: [Unicode.Scalar: String] = [:]
        for line in data.split(whereSeparator: \.isNewline) {
            let fields = line.prefix(while: { $0 != "#" }).split(separator: ";")
            guard fields.count >= 2,
                  let source = UInt32(fields[0].trimmingCharacters(in: .whitespaces), radix: 16),
                  let scalar = Unicode.Scalar(source) else { continue }
            let codes = fields[1].split(whereSeparator: \.isWhitespace)
            let targets = codes.compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
            guard !targets.isEmpty, targets.count == codes.count else { continue }
            mapping[scalar] = String(String.UnicodeScalarView(targets))
        }
        return mapping.isEmpty ? nil : mapping
    }()

    private static func hex(_ bytes: String.UTF8View) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
