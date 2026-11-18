import Foundation
import Testing
@testable import UtilityCore

struct MouseFixesTests {
    @Test func appliesOnlyVerifiedSelectorsAndRestoresWithoutOverwritingOtherEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "linearmouse.json")
        try Data(fixture.utf8).write(to: config)
        let initial = try MouseFixes.inspect(config)
        #expect(initial.devices.count == 2)
        #expect(!initial.applied)
        try apply(to: config, from: initial)
        #expect(try MouseFixes.inspect(config).applied)
        var document = try read(config)
        var schemes = try #require(document["schemes"] as? [[String: Any]])
        #expect(schemes.count == 5)
        let mouse = try #require((schemes[3]["if"] as? [String: Any])?["device"] as? [String: Any])
        #expect(mouse["productID"] as? String == "0x0a20")
        #expect(mouse["serialNumber"] as? String == "TEST1234")
        let mouseScroll = try #require(schemes[3]["scrolling"] as? [String: Any])
        #expect((mouseScroll["reverse"] as? [String: Bool])?["vertical"] == true)
        #expect((mouseScroll["smoothed"] as? [String: Any])?["vertical"] != nil)
        let trackpadScroll = try #require(schemes[4]["scrolling"] as? [String: Any])
        #expect((trackpadScroll["reverse"] as? [String: Bool])?["vertical"] == false)
        #expect(trackpadScroll["smoothed"] == nil)
        schemes.append(["pointer": ["speed": 0.4]])
        document["schemes"] = schemes
        try JSONSerialization.data(withJSONObject: document).write(to: config)

        try MouseFixes.restore(config)
        #expect(!(try MouseFixes.inspect(config).applied))
        let restored = try read(config)
        #expect(restored["unrelated"] as? String == "preserve")
        let remaining = try #require(restored["schemes"] as? [[String: Any]])
        #expect(remaining.count == 4)
        #expect((remaining.last?["pointer"] as? [String: Double])?["speed"] == 0.4)
    }

    @Test func refusesToUseReceiverAndCategoryOnlySelectors() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "linearmouse.json")
        let text = """
        {"schemes":[
          {"if":{"device":{"category":"mouse"}}},
          {"if":{"device":{"category":"mouse","vendorID":"0x046d","productID":"0xc548","productName":"Receiver"}}}
        ]}
        """
        try Data(text.utf8).write(to: config)
        #expect(try MouseFixes.inspect(config).devices.isEmpty)
    }

    @Test func refusesToRestoreAnEditedOverlay() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "linearmouse.json")
        try Data(fixture.utf8).write(to: config)
        try apply(to: config, from: MouseFixes.inspect(config))

        var document = try read(config)
        var schemes = try #require(document["schemes"] as? [[String: Any]])
        schemes[3]["scrolling"] = ["reverse": ["vertical": false]]
        document["schemes"] = schemes
        let updated = try JSONSerialization.data(withJSONObject: document)
        try updated.write(to: config)
        #expect(throws: ToolError.self) { try MouseFixes.restore(config) }
        #expect(try Data(contentsOf: config) == updated)
    }

    private func apply(to config: URL, from snapshot: MouseFixes.Snapshot) throws {
        let mouse = try #require(snapshot.devices.first(where: { $0.category == .mouse }))
        let trackpad = try #require(snapshot.devices.first(where: { $0.category == .trackpad }))
        try MouseFixes.apply(config, mouse: .init(device: mouse, direction: .reverse),
                             trackpad: .init(device: trackpad, direction: .system), smoothing: 0.65)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private let fixture = """
    {
      "$schema": "https://schema.linearmouse.app/0.12.0",
      "unrelated": "preserve",
      "schemes": [
        {"if":{"device":{"category":"mouse"}},"scrolling":{"speed":1}},
        {"if":{"device":{"category":"mouse","vendorID":"0x1234","productID":"0x0A20","productName":"Test mouse","serialNumber":"TEST1234"}},"pointer":{"speed":0.2}},
        {"if":{"device":{"category":"trackpad","vendorID":"0x05ac","productID":"0x0274","productName":"Test trackpad"}},"pointer":{"speed":0.1}}
      ]
    }
    """
}
