import Foundation
import Testing
import UtilityCore

struct UUIDGeneratorTests {
    @Test func generatesRFCVariantsAndPreservesMillisecondTime() throws {
        let random = try UUIDGenerator.generate(.random, count: 12, uppercase: true)
        #expect(Set(random).count == 12)
        for value in random {
            #expect(value.count == 36 && value == value.uppercased())
            let details = try UUIDGenerator.inspect(value)
            #expect(details.version == 4 && details.variant == "RFC 9562")
            #expect(details.unixMilliseconds == nil)
        }

        let moment = Date(timeIntervalSince1970: 1_645_557_742)
        let timeBased = try UUIDGenerator.generate(.timestamped, count: 12, hyphenated: false, now: moment)
        #expect(Set(timeBased).count == 12)
        for value in timeBased {
            #expect(value.count == 32 && value == value.lowercased())
            let details = try UUIDGenerator.inspect(value)
            #expect(details.version == 7 && details.variant == "RFC 9562")
            #expect(details.unixMilliseconds == 1_645_557_742_000)
        }
    }

    @Test func inspectsPublishedV7VectorAndRejectsInvalidInput() throws {
        let details = try UUIDGenerator.inspect("017f22e2-79b0-7cc3-98c4-dc0c0c07398f")
        #expect(details.unixMilliseconds == 1_645_557_742_000)
        let nilUUID = try UUIDGenerator.inspect("00000000-0000-0000-0000-000000000000")
        #expect(nilUUID.version == nil && nilUUID.unixMilliseconds == nil)
        #expect(throws: ToolError.self) { try UUIDGenerator.inspect("invalid") }
        #expect(throws: ToolError.self) { try UUIDGenerator.generate(.random, count: 0) }
    }

    @Test func acceptsAndCopiesCanonicalUUIDURN() throws {
        let bare = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
        let details = try UUIDGenerator.inspect("  URN:UUID:\(bare.uppercased())\n")
        #expect(details.canonicalUUID == bare)
        #expect(details.urn == "urn:uuid:" + bare)
        #expect(details.version == 7 && details.unixMilliseconds == 1_645_557_742_000)
        #expect(try UUIDGenerator.inspect(details.urn) == details)
        #expect(try UUIDGenerator.inspect(bare.replacingOccurrences(of: "-", with: "")) == details)
    }

    @Test(arguments: [
        "urn:uuid:017f22e279b07cc398c4dc0c0c07398f",
        "urn:uuid:017f22e2-79b0-7cc3-98c4-dc0c0c07398f?+query",
        "urn:other:017f22e2-79b0-7cc3-98c4-dc0c0c07398f",
        "urn:uuid: 017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
    ])
    func rejectsUnsupportedUUIDInputForms(_ input: String) {
        #expect(throws: ToolError.self) { try UUIDGenerator.inspect(input) }
    }
}
