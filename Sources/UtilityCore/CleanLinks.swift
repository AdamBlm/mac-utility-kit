import Foundation

public enum CleanLinks {
    public struct Result: Equatable, Sendable {
        public let original: String
        public let cleaned: String
        public let removedParameters: [String]
        public let redirectDestination: String?
        public let keptSignedQuery: Bool
    }

    package struct BatchRow: Identifiable {
        package let id: Int
        package let input: String
        package let result: Swift.Result<Result, Error>
    }

    package static func cleanBatch(_ input: String, unwrapRedirects: Bool) throws -> [BatchRow] {
        guard input.utf8.count <= 1_048_576 else {
            throw ToolError.invalid("Enter up to 1 MB of links at a time.")
        }
        let lines = input.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count <= 500 else {
            throw ToolError.invalid("Enter up to 500 links at a time.")
        }
        return lines.enumerated().map { index, line in
            BatchRow(id: index, input: line, result: Swift.Result {
                try clean(line, unwrapRedirects: unwrapRedirects)
            })
        }
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

    public static func clean(_ input: String, unwrapRedirects: Bool = true) throws -> Result {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = try parse(original)
        let redirect = try redirectDestination(in: source)
        if let redirect {
            let wrapperFields = queryFields((source.percentEncodedQuery ?? "").unicodeScalars[...])
            let signed = wrapperFields.contains { signatureKeys.contains(asciiKey($0.key)) }
            if !unwrapRedirects || signed {
                return Result(original: original, cleaned: original, removedParameters: [],
                              redirectDestination: redirect, keptSignedQuery: signed)
            }
        }
        let address = redirect ?? original
        let scalars = address.unicodeScalars
        let fragmentOrEnd = scalars.firstIndex(of: "#") ?? scalars.endIndex
        guard let questionMark = scalars[..<fragmentOrEnd].firstIndex(of: "?") else {
            return Result(original: original, cleaned: address, removedParameters: [],
                          redirectDestination: redirect, keptSignedQuery: false)
        }
        let items = queryFields(scalars[scalars.index(after: questionMark)..<fragmentOrEnd])
        guard !items.contains(where: { signatureKeys.contains(asciiKey($0.key)) }) else {
            return Result(original: original, cleaned: address, removedParameters: [],
                          redirectDestination: redirect, keptSignedQuery: true)
        }
        let removed = items.filter { trackingKeys.contains(asciiKey($0.key)) }
        guard !removed.isEmpty else {
            return Result(original: original, cleaned: address, removedParameters: [],
                          redirectDestination: redirect, keptSignedQuery: false)
        }
        let kept = items.filter { !trackingKeys.contains(asciiKey($0.key)) }.map(\.raw)
        let suffix = kept.isEmpty ? "" : "?" + kept.joined(separator: "&")
        let cleaned = String(scalars[..<questionMark]) + suffix + String(scalars[fragmentOrEnd...])
        return Result(original: original, cleaned: cleaned, removedParameters: removed.map(\.key),
                      redirectDestination: redirect, keptSignedQuery: false)
    }

    private static func parse(_ address: String) throws -> URLComponents {
        guard address.utf8.count <= 32_768, !address.isEmpty,
              !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !address.contains("\\"), validPercentEscapes(address),
              hasValidASCIISyntax(address),
              let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.url != nil, hasValidPort(address, schemeLength: scheme.utf8.count) else {
            throw ToolError.invalid("Enter a valid HTTP or HTTPS link.")
        }
        return components
    }

    private static func hasValidPort(_ address: String, schemeLength: Int) -> Bool {
        // URLComponents can omit a port whose value overflows Int. Check the original authority.
        let authority = address.unicodeScalars.dropFirst(schemeLength + 3).prefix { !"/?#".unicodeScalars.contains($0) }
        guard let colon = authority.lastIndex(of: ":"), authority.last != "]" else { return true }
        let port = authority.suffix(from: authority.index(after: colon))
        return port.isEmpty || UInt16(String(port)) != nil
    }

    private static func hasValidASCIISyntax(_ address: String) -> Bool {
        // Let Foundation encode Unicode while checking that it has no malformed ASCII syntax to repair.
        let projection = String(decoding: address.utf8.map { $0 < 128 ? $0 : 120 }, as: UTF8.self)
        return URL(string: projection, encodingInvalidCharacters: false) != nil
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

    private static func queryFields(_ query: String.UnicodeScalarView.SubSequence) -> [(raw: String, key: String)] {
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
