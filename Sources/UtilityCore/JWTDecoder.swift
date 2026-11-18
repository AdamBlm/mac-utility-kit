import CryptoKit
import Foundation

public enum JWTDecoder {
    public static let maximumTokenBytes = 128 * 1024

    public enum Algorithm: String, CaseIterable, Identifiable, Sendable {
        case hs256 = "HS256"
        case hs384 = "HS384"
        case hs512 = "HS512"

        public var id: Self { self }
        public var keyByteCount: Int {
            switch self {
            case .hs256: 32
            case .hs384: 48
            case .hs512: 64
            }
        }
    }

    public enum KeyEncoding: String, CaseIterable, Identifiable, Sendable {
        case utf8 = "UTF-8"
        case base64 = "Base64"
        case base64URL = "Base64URL"
        case hex = "Hex"

        public var id: Self { self }

        fileprivate func decode(_ secret: String) throws -> Data {
            switch self {
            case .utf8: Data(secret.utf8)
            case .base64: try ByteEncoding.base64.decode(secret)
            case .base64URL: try ByteEncoding.base64URL.decode(secret)
            case .hex: try ByteEncoding.hex.decode(secret)
            }
        }
    }

    public enum TimeWindow: String, Sendable {
        case unbounded = "No expiry or not-before claim"
        case current = "Within the claimed time window"
        case notYetValid = "Before the claimed time window"
        case expired = "Past the claimed expiry"
        case invalid = "Invalid time window"
    }

    public struct NumericDate: Sendable {
        public let source: String
        public let seconds: Double

        public var date: Date? {
            guard (-62_135_596_800...253_402_300_799).contains(seconds) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    public struct Token: Sendable {
        public let header: String
        public let payload: String
        public let algorithm: String
        public let issuedAt: NumericDate?
        public let expires: NumericDate?
        public let notBefore: NumericDate?

        fileprivate let signingInput: Data
        fileprivate let signature: Data

        public func timeWindow(at date: Date) -> TimeWindow {
            let now = date.timeIntervalSince1970
            if let expires, let notBefore, expires.seconds <= notBefore.seconds { return .invalid }
            if let expires, now >= expires.seconds { return .expired }
            if let notBefore, now < notBefore.seconds { return .notYetValid }
            if expires == nil, notBefore == nil { return .unbounded }
            return .current
        }
    }

    public struct Issue: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func decode(_ input: String) throws -> Token {
        guard input.utf8.count <= maximumTokenBytes else {
            throw Issue(message: "The token must be no larger than 128 KiB.")
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", maxSplits: 4, omittingEmptySubsequences: false)
        if parts.count == 5 {
            throw Issue(message: "Encrypted JWTs (JWE) are unsupported.")
        }
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw Issue(message: "Enter a JWT with a compact header, payload, and signature.")
        }
        let header = try jsonObject(parts[0], name: "header")
        let payload = try jsonObject(parts[1], name: "payload")
        guard let algorithm = header.values["alg"].flatMap(string), !algorithm.isEmpty else {
            throw Issue(message: "The JWT header must contain a nonempty string alg.")
        }
        guard header.values["crit"] == nil else {
            throw Issue(message: "Critical JWT header extensions are unsupported.")
        }
        if let encoding = header.values["b64"] {
            guard case .token("true") = encoding else {
                throw Issue(message: "JWT payloads must use Base64URL encoding.")
            }
        }
        let signature = try base64URL(parts[2], name: "signature")
        guard (algorithm == "none") == signature.isEmpty else {
            throw Issue(message: "The signature segment does not match the JWT header algorithm.")
        }
        if let supported = Algorithm(rawValue: algorithm), signature.count != supported.keyByteCount {
            throw Issue(message: "\(algorithm) signatures must contain \(supported.keyByteCount) bytes.")
        }
        let signingInput = Data((parts[0] + "." + parts[1]).utf8)
        return Token(header: header.formatted, payload: payload.formatted, algorithm: algorithm,
                     issuedAt: try numericDate(payload.values["iat"], name: "iat"),
                     expires: try numericDate(payload.values["exp"], name: "exp"),
                     notBefore: try numericDate(payload.values["nbf"], name: "nbf"),
                     signingInput: signingInput, signature: signature)
    }

    public static func verify(
        _ token: Token, algorithm: Algorithm, secret: String, encoding: KeyEncoding = .utf8
    ) throws -> Bool {
        guard token.algorithm == algorithm.rawValue else {
            throw Issue(message: "The selected \(algorithm.rawValue) algorithm differs from the JWT header.")
        }
        guard secret.utf8.count <= 64 * 1024 else {
            throw Issue(message: "The supplied key must be no larger than 64 KiB.")
        }
        let bytes = try encoding.decode(secret)
        guard bytes.count >= algorithm.keyByteCount else {
            throw Issue(message: "\(algorithm.rawValue) requires a key of at least \(algorithm.keyByteCount) bytes.")
        }
        let key = SymmetricKey(data: bytes)
        switch algorithm {
        case .hs256:
            return HMAC<SHA256>.isValidAuthenticationCode(token.signature, authenticating: token.signingInput, using: key)
        case .hs384:
            return HMAC<SHA384>.isValidAuthenticationCode(token.signature, authenticating: token.signingInput, using: key)
        case .hs512:
            return HMAC<SHA512>.isValidAuthenticationCode(token.signature, authenticating: token.signingInput, using: key)
        }
    }

    private static func jsonObject(
        _ input: Substring, name: String
    ) throws -> (values: [String: JSONNode], formatted: String) {
        let data = try base64URL(input, name: name)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Issue(message: "The JWT \(name) is not UTF-8.")
        }
        do {
            let result = try JSONFormatter.format(text)
            guard result.duplicateKeys.isEmpty else {
                throw Issue(message: "The JWT \(name) contains duplicate JSON keys.")
            }
            guard case .object(let members) = try JSONFormatter.parsedValue(text) else {
                throw Issue(message: "The JWT \(name) must be a JSON object.")
            }
            // Only exact ASCII registered names are used for verification and time checks.
            let values: [String: JSONNode] = Dictionary(uniqueKeysWithValues: members.compactMap { member in
                guard member.key.allSatisfy({ $0 < 128 }) else { return nil }
                return (String(decoding: member.key, as: UTF8.self), member.value)
            })
            return (values, result.text)
        } catch let error as JSONFormatError {
            throw Issue(message: "Invalid JSON in the JWT \(name). \(error.localizedDescription)")
        }
    }

    private static func base64URL(_ input: Substring, name: String) throws -> Data {
        guard input.utf8.allSatisfy({
            switch $0 {
            case 45, 48...57, 65...90, 95, 97...122: true
            default: false
            }
        }), let data = try? ByteEncoding.base64URL.decode(String(input)) else {
            throw Issue(message: "The JWT \(name) must use unpadded Base64URL.")
        }
        return data
    }

    private static func string(_ node: JSONNode) -> String? {
        guard case .token(let raw) = node, raw.utf8.first == 34 else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
    }

    private static func numericDate(_ node: JSONNode?, name: String) throws -> NumericDate? {
        guard let node else { return nil }
        guard case .token(let raw) = node, let seconds = Double(raw), seconds.isFinite else {
            throw Issue(message: "The \(name) claim must be a finite number of seconds since the Unix epoch.")
        }
        return NumericDate(source: raw, seconds: seconds)
    }
}
