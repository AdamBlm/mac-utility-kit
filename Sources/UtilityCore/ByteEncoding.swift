import Foundation

public enum ByteEncoding: String, CaseIterable, Identifiable, Sendable {
    case base64 = "Base64"
    case base64URL = "Base64URL"
    case hex = "Hex"
    case binary = "Binary"

    public var id: Self { self }
    public var supportsPadding: Bool { self == .base64 || self == .base64URL }

    public func encode(_ data: Data, padded: Bool = true, wrapAt: Int? = nil) -> String {
        var output: String
        switch self {
        case .base64, .base64URL:
            output = data.base64EncodedString()
            if self == .base64URL {
                output = output.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            }
            if !padded {
                while output.last == "=" { output.removeLast() }
            }
        case .hex:
            let digits = Array("0123456789abcdef".utf8)
            var result = [UInt8]()
            result.reserveCapacity(data.count * 2)
            for byte in data {
                result.append(digits[Int(byte >> 4)])
                result.append(digits[Int(byte & 15)])
            }
            output = String(decoding: result, as: UTF8.self)
        case .binary:
            var result = [UInt8]()
            result.reserveCapacity(data.count * 8)
            for byte in data {
                for bit in (0..<8).reversed() {
                    result.append(48 + ((byte >> bit) & 1))
                }
            }
            output = String(decoding: result, as: UTF8.self)
        }
        guard let width = wrapAt, width > 0, output.utf8.count > width else { return output }
        var wrapped = [UInt8]()
        for (index, byte) in output.utf8.enumerated() {
            if index > 0 && index.isMultiple(of: width) { wrapped.append(10) }
            wrapped.append(byte)
        }
        return String(decoding: wrapped, as: UTF8.self)
    }

    public func decode(_ text: String) throws -> Data {
        try decodeDigits(filteredDigits(text.utf8))
    }

    package func decode(bytes: Data) throws -> Data {
        try decodeDigits(filteredDigits(bytes))
    }

    func filteredDigits(_ bytes: some Collection<UInt8>, after previousBytes: Int = 0) throws -> [UInt8] {
        var digits: [UInt8] = []
        digits.reserveCapacity(bytes.count)
        for (index, byte) in bytes.enumerated() {
            if byte == 9 || byte == 10 || byte == 13 || byte == 32 { continue }
            let valid: Bool
            switch self {
            case .base64, .base64URL:
                valid = switch byte {
                case 48...57, 65...90, 97...122, 61: true
                case 43, 47: self == .base64
                case 45, 95: self == .base64URL
                default: false
                }
            case .hex: valid = (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            case .binary: valid = byte == 48 || byte == 49
            }
            guard valid else { throw ByteEncodingError.invalidCharacterAt(byte: previousBytes + index + 1) }
            digits.append(byte)
        }
        return digits
    }

    func decodeDigits(_ bytes: [UInt8]) throws -> Data {
        switch self {
        case .base64, .base64URL:
            return try decodeBase64(bytes)
        case .hex, .binary:
            let width = self == .hex ? 2 : 8
            let base: UInt8 = self == .hex ? 16 : 2
            var output = Data()
            var byte: UInt8 = 0
            for (index, character) in bytes.enumerated() {
                let digit: UInt8
                switch character {
                case 48...57: digit = character - 48
                case 65...70: digit = character - 55
                case 97...102: digit = character - 87
                default: throw ByteEncodingError.invalidCharacter
                }
                guard digit < base else { throw ByteEncodingError.invalidCharacter }
                byte = byte * base + digit
                if (index + 1).isMultiple(of: width) {
                    output.append(byte)
                    byte = 0
                }
            }
            guard bytes.count.isMultiple(of: width) else { throw ByteEncodingError.incompleteByte(width) }
            return output
        }
    }

    private func decodeBase64(_ bytes: [UInt8]) throws -> Data {
        var normalized = [UInt8]()
        var paddingCount = 0
        for byte in bytes {
            if byte == 61 {
                paddingCount += 1
                continue
            }
            guard paddingCount == 0 else { throw ByteEncodingError.invalidPadding }
            switch byte {
            case 48...57, 65...90, 97...122: normalized.append(byte)
            case 43, 47:
                guard self == .base64 else { throw ByteEncodingError.invalidCharacter }
                normalized.append(byte)
            case 45, 95:
                guard self == .base64URL else { throw ByteEncodingError.invalidCharacter }
                normalized.append(byte == 45 ? 43 : 47)
            default: throw ByteEncodingError.invalidCharacter
            }
        }
        let remainder = normalized.count % 4
        guard remainder != 1 else { throw ByteEncodingError.invalidPadding }
        let required = (4 - remainder) % 4
        guard paddingCount == 0 || paddingCount == required else { throw ByteEncodingError.invalidPadding }
        normalized.append(contentsOf: repeatElement(61, count: required))
        let padded = String(decoding: normalized, as: UTF8.self)
        guard let decoded = Data(base64Encoded: padded), decoded.base64EncodedString() == padded else {
            throw ByteEncodingError.invalidPadding
        }
        return decoded
    }
}

public enum ByteEncodingError: LocalizedError {
    case invalidCharacter
    case invalidCharacterAt(byte: Int)
    case invalidPadding
    case incompleteByte(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCharacter: "Input contains a character outside the selected alphabet."
        case .invalidCharacterAt(let byte): "Input byte \(byte) is outside the selected alphabet."
        case .invalidPadding: "Input has an invalid Base64 length, padding, or trailing bits."
        case .incompleteByte(let width): "Each byte requires exactly \(width) digits."
        }
    }
}
