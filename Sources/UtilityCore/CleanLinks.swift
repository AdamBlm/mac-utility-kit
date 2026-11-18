import Foundation

public enum CleanLinks {
    public struct Result: Equatable, Sendable {
        public let original: String
        public let cleaned: String
        public let removedParameters: [String]
        public let redirectDestination: String?
    }

    private static let trackingKeys: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "ttclid",
        "twclid", "li_fat_id", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "igshid",
        "utm_id", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_source_platform", "utm_creative_format", "utm_marketing_tactic"
    ]

    private static let signatureKeys: Set<String> = [
        "signature", "sig", "x-amz-signature", "x-goog-signature", "oauth_signature",
        "x-ms-signature", "policy", "key-pair-id"
    ]

    public static func clean(_ input: String) throws -> Result {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = try parse(original)
        let redirect = try redirectDestination(in: source)
        let address = redirect ?? original
        let components = redirect == nil ? source : try parse(address)
        let items = queryFields(components)
        guard !items.contains(where: { signatureKeys.contains(asciiKey($0.key)) }) else {
            return Result(original: original, cleaned: address, removedParameters: [], redirectDestination: redirect)
        }
        let removed = items.filter { trackingKeys.contains(asciiKey($0.key)) }
        let fragmentOrEnd = address.firstIndex(of: "#") ?? address.endIndex
        guard !removed.isEmpty, let query = components.percentEncodedQuery,
              let questionMark = address[..<fragmentOrEnd].firstIndex(of: "?"),
              address[address.index(after: questionMark)..<fragmentOrEnd] == query else {
            return Result(original: original, cleaned: address, removedParameters: [], redirectDestination: redirect)
        }
        let kept = items.filter { !trackingKeys.contains(asciiKey($0.key)) }.map(\.raw)
        let suffix = kept.isEmpty ? "" : "?" + kept.joined(separator: "&")
        let cleaned = String(address[..<questionMark]) + suffix + address[fragmentOrEnd...]
        return Result(original: original, cleaned: cleaned, removedParameters: removed.map(\.key), redirectDestination: redirect)
    }

    private static func parse(_ address: String) throws -> URLComponents {
        guard address.utf8.count <= 32_768, !address.isEmpty,
              !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              URL(string: address, encodingInvalidCharacters: false) != nil,
              let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              !address.contains("\\"), validPercentEscapes(address) else {
            throw ToolError.invalid("Enter a valid HTTP or HTTPS link.")
        }
        return components
    }

    private static func asciiKey(_ key: String) -> String {
        key.utf8.allSatisfy { $0 < 0x80 } ? key.lowercased() : key
    }

    private static func validPercentEscapes(_ address: String) -> Bool {
        let bytes = Array(address.utf8)
        return bytes.indices.allSatisfy { index in
            bytes[index] != 37 || (index + 2 < bytes.count && isHexDigit(bytes[index + 1]) && isHexDigit(bytes[index + 2]))
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func queryFields(_ components: URLComponents) -> [(raw: String, key: String)] {
        guard let query = components.percentEncodedQuery else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: false).map { field in
            let name = field.prefix { $0 != "=" }
            return (String(field), String(name).removingPercentEncoding ?? String(name))
        }
    }

    private static func redirectDestination(in components: URLComponents) throws -> String? {
        if let port = components.port {
            let defaultPort = components.scheme?.lowercased() == "https" ? 443 : 80
            guard port == defaultPort else { return nil }
        }
        let parameters: [String]
        switch (components.host?.lowercased(), components.percentEncodedPath) {
        case ("www.google.com", "/url"), ("google.com", "/url"): parameters = ["url", "q"]
        case ("www.youtube.com", "/redirect"), ("youtube.com", "/redirect"): parameters = ["q"]
        case ("l.facebook.com", "/l.php"), ("lm.facebook.com", "/l.php"): parameters = ["u"]
        default: return nil
        }
        let matches = (components.queryItems ?? []).filter { parameters.contains($0.name) }
        guard matches.count <= 1 else { throw ToolError.invalid("The redirect link contains multiple destinations.") }
        guard let value = matches.first?.value else { throw ToolError.invalid("The redirect link has no destination.") }
        _ = try parse(value)
        return value
    }
}
