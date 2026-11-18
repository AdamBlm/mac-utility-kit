import Foundation
import Testing
@testable import UtilityCore

struct DisplayControlTests {
    private static let uuid = "10ACB8A0-0000-0000-1419-0104A2435078"
    private static let secondary = "A73419EE-0000-0000-1111-222233334444"

    @Test func parsesDetailedListingAndRejectsAmbiguousRecords() {
        let base = Self.listing(uuid: Self.uuid, id: 48, model: "Display (HDR)")
            + Self.listing(uuid: Self.secondary, id: 49, model: "Laptop")
        let records = DisplayControl.parseDisplays(base)
        #expect(records.map(\.name) == ["Display (HDR)", "Laptop"])
        #expect(records.map(\.displayID) == [48, 49])
        #expect(DisplayControl.parseDisplays(base + Self.listing(uuid: Self.uuid, id: 50, model: "Duplicate")).map(\.displayID) == [49])
        #expect(DisplayControl.parseDisplays("[1] A (not-a-uuid)\n - Display ID: 7").isEmpty)
    }

    @Test func queriesOnlyDetectedExternalDisplayAndReadsNativeRanges() async throws {
        let mock = Mock()
        let adapter = DisplayControl(command: { try await mock.run($0) }, connectedExternalIDs: { [48] })
        let displays = try await adapter.displays()
        #expect(displays.map(\.displayID) == [48])
        let display = try #require(displays.first)
        let settings = try await adapter.settings(for: display)
        #expect(settings[.brightness]?.current == 42)
        #expect(settings[.brightness]?.maximum == 255)
        #expect(settings[.contrast] == nil)
        #expect(settings[.volume] == nil)
        #expect(await mock.setCommands.isEmpty)
    }

    @Test func scopesWritesAndRequiresReadback() async throws {
        let mock = Mock()
        let adapter = DisplayControl(command: { try await mock.run($0) }, connectedExternalIDs: { [48] })
        let available = try await adapter.displays()
        let display = try #require(available.first)
        await #expect(throws: ToolError.self) {
            try await adapter.apply(256, feature: .brightness, on: display)
        }
        #expect(await mock.setCommands.isEmpty)

        let accepted = try await adapter.apply(190, feature: .brightness, on: display)
        #expect(accepted == .accepted(.init(current: 190, maximum: 255)))
        #expect(await mock.setCommands == [["display", "uuid=" + Self.uuid, "set", "luminance", "190"]])

        await mock.rejectUpdates()
        let denied = try await adapter.apply(191, feature: .brightness, on: display)
        #expect(denied == .notAccepted(.init(current: 190, maximum: 255)))
        await mock.failNextReadback()
        let unconfirmed = try await adapter.apply(192, feature: .brightness, on: display)
        #expect(unconfirmed == .unconfirmed)
        await mock.disconnect()
        await #expect(throws: ToolError.self) {
            try await adapter.apply(50, feature: .brightness, on: display)
        }
        #expect(await mock.setCommands.count == 3)
    }

    private static func listing(uuid: String, id: Int, model: String) -> String {
        """
        [1] \(model) (\(uuid))
         - Product name:  \(model)
         - Display ID:    \(id)
         - System UUID:   \(uuid)

        """
    }

    private actor Mock {
        private var current = 42
        private var accepts = true
        private var connected = true
        private var failReadbackAtCount: Int?
        private(set) var setCommands: [[String]] = []

        func rejectUpdates() { accepts = false }
        func failNextReadback() { failReadbackAtCount = setCommands.count + 1 }
        func disconnect() { connected = false }

        func run(_ args: [String]) throws -> String {
            if args == ["display", "list", "detailed"] {
                let other = listing(uuid: secondary, id: 49, model: "Laptop")
                return connected ? listing(uuid: uuid, id: 48, model: "External") + other : other
            }
            guard args.count >= 4, args[1] == "uuid=" + uuid else { throw ToolError.invalid("Unexpected display selector") }
            let command = args[2], feature = args[3]
            switch (command, feature) {
            case ("get", "luminance"):
                if failReadbackAtCount == setCommands.count { throw ToolError.invalid("Readback failed") }
                return "\(current)\n"
            case ("max", "luminance"): return "255\n"
            case ("get", "contrast"): return "100\n"
            case ("max", "contrast"): return "99\n"
            case ("get", "volume"): throw ToolError.invalid("Unsupported")
            case ("set", "luminance"):
                setCommands.append(args)
                if accepts, let value = Int(args[4]) { current = value }
                return "Writing \(args[4])"
            default: throw ToolError.invalid("Unexpected command")
            }
        }
    }
}
