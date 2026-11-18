import Foundation
import Testing
import UtilityCore

struct JWTDecoderTests {
    private static let key = "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow"
    private static let standardParts = [
        "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9",
        "eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ",
        "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    ]

    @Test func verifiesRFC7515SignatureOnTheOriginalSigningInput() throws {
        let token = try JWTDecoder.decode(Self.standardParts.joined(separator: "."))
        #expect(token.header.contains("\"typ\": \"JWT\""))
        #expect(token.expires?.seconds == 1_300_819_380)
        #expect(try JWTDecoder.verify(token, algorithm: .hs256, secret: Self.key, encoding: .base64URL))
        #expect(try !JWTDecoder.verify(token, algorithm: .hs256, secret: String(repeating: "a", count: 32)))
        #expect(throws: JWTDecoder.Issue.self) {
            try JWTDecoder.verify(token, algorithm: .hs384, secret: Self.key, encoding: .base64URL)
        }
        #expect(throws: JWTDecoder.Issue.self) {
            try JWTDecoder.verify(token, algorithm: .hs256, secret: "short key")
        }
        var tampered = Self.standardParts
        tampered[1] = ByteEncoding.base64URL.encode(Data(#"{"iss":"other"}"#.utf8), padded: false)
        let altered = try JWTDecoder.decode(tampered.joined(separator: "."))
        #expect(try !JWTDecoder.verify(altered, algorithm: .hs256, secret: Self.key, encoding: .base64URL))
    }

    @Test(arguments: [
        (JWTDecoder.Algorithm.hs384, "eyJhbGciOiJIUzM4NCJ9.eyJuYmYiOjEwMC4yNSwiZXhwIjoxMDIuNX0.gIBBPpxxn3jtjTcW4MwkXrAtQRtkXBLqYsWecHbt-FsHJPmLJ6QEV-5Tm3_59Muc"),
        (.hs512, "eyJhbGciOiJIUzUxMiJ9.eyJuYmYiOjEwMC4yNSwiZXhwIjoxMDIuNX0.qLkqB88QEjFKK10k_iiHyEFUOY3CYSetDY7qd4ghVQPKdvAYfig3bWeykld41aFdOf5_l8XxIUnnSw3ymjS5_w"),
    ])
    func verifiesIndependentHMACVectors(algorithm: JWTDecoder.Algorithm, fixture: String) throws {
        let token = try JWTDecoder.decode(fixture)
        #expect(try JWTDecoder.verify(token, algorithm: algorithm, secret: String(repeating: "x", count: algorithm.keyByteCount)))
    }

    @Test func timeWindowUsesNumericDateAndExactBoundaries() throws {
        let token = try JWTDecoder.decode(compact(payload: #"{"iat":-1.5,"nbf":100.25,"exp":102.5}"#))
        #expect(token.issuedAt?.source == "-1.5")
        #expect(token.issuedAt?.seconds == -1.5)
        #expect(token.timeWindow(at: Date(timeIntervalSince1970: 100.249)) == .notYetValid)
        #expect(token.timeWindow(at: Date(timeIntervalSince1970: 100.25)) == .current)
        #expect(token.timeWindow(at: Date(timeIntervalSince1970: 102.5)) == .expired)
        let invalid = try JWTDecoder.decode(compact(payload: #"{"nbf":100.25,"exp":100.25}"#))
        #expect(invalid.timeWindow(at: .now) == .invalid)
    }

    @Test func rejectsAmbiguousOrMalformedTokensAndNeverVerifiesUnsecuredTokens() throws {
        let invalid = [
            compact(header: #"{"alg":"HS256","alg":"none"}"#),
            compact(header: #"{"alg":"none","crit":["custom"],"custom":true}"#),
            compact(header: #"{"alg":"none","b64":false}"#),
            compact(header: #"{"alg":null}"#),
            compact(payload: #"{"exp":"100"}"#),
            compact(payload: #"{"exp":true}"#),
            compact(payload: #"{"exp":1,"exp":2}"#),
            compact(payload: "[]"),
            compact() + "AAAA",
            compact().replacingOccurrences(of: ".", with: "=.", options: [], range: compact().range(of: ".")),
            Self.standardParts.joined(separator: ".") + "=",
            Self.standardParts[0] + "." + Self.standardParts[1] + ".AA",
            "a.b.c.d.e", "a.."
        ]
        for candidate in invalid {
            #expect(throws: JWTDecoder.Issue.self) { try JWTDecoder.decode(candidate) }
        }
        let unsecured = try JWTDecoder.decode(compact())
        #expect(unsecured.algorithm == "none")
        #expect(throws: JWTDecoder.Issue.self) {
            try JWTDecoder.verify(unsecured, algorithm: .hs256, secret: Self.key, encoding: .base64URL)
        }
    }

    private func compact(header: String = #"{"alg":"none"}"#, payload: String = "{}") -> String {
        let encode = ByteEncoding.base64URL
        return encode.encode(Data(header.utf8), padded: false) + "." + encode.encode(Data(payload.utf8), padded: false) + "."
    }
}
