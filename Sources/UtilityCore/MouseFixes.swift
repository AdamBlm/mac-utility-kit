import CryptoKit
import Foundation

package enum MouseFixes {
    package enum Category: String, Sendable { case mouse, trackpad }
    package enum Direction: String, CaseIterable, Sendable {
        case inherit = "Keep LinearMouse setting"
        case system = "Follow macOS direction"
        case reverse = "Reverse macOS direction"
    }

    package struct Device: Hashable, Identifiable, Sendable {
        package let category: Category
        let vendor: Int
        let product: Int
        let name: String?
        let serial: String?

        package var id: Self { self }
        package var title: String {
            let identity = String(format: "%04X:%04X", vendor, product)
            return [name, identity, serial.map { "••" + String($0.suffix(4)) }].compactMap { $0 }.joined(separator: " · ")
        }

        fileprivate var matcher: [String: Any] {
            var fields = ["category": category.rawValue, "vendorID": Self.hex(vendor), "productID": Self.hex(product)]
            fields["productName"] = name
            fields["serialNumber"] = serial
            return fields
        }

        private static func hex(_ value: Int) -> String { String(format: "0x%04x", value) }
    }

    package struct Selection: Sendable {
        var device: Device
        var direction: Direction

        package init(device: Device, direction: Direction) {
            self.device = device
            self.direction = direction
        }
    }

    package struct Snapshot: Sendable {
        package let devices: [Device]
        package let applied: Bool
    }

    private struct Journal: Codable {
        let originalDigest: Data
        let overlays: Data
    }

    package static func inspect(_ config: URL) throws -> Snapshot {
        let original = try read(config)
        let (_, schemes) = try document(original)
        var base = schemes
        if let managed = try loadJournal(for: config), managed.originalDigest != digest(original) {
            base.removeSubrange(try managedRange(managed.overlays, in: schemes))
            return Snapshot(devices: devices(from: base), applied: true)
        }
        return Snapshot(devices: devices(from: base), applied: false)
    }

    package static func apply(
        _ config: URL, mouse: Selection, trackpad: Selection, smoothing: Double?
    ) throws {
        let original = try read(config)
        var (root, schemes) = try document(original)
        if let managed = try loadJournal(for: config), managed.originalDigest != digest(original) {
            throw ToolError.invalid("Restore the previous scroll profiles before applying new ones.")
        }
        let available = devices(from: schemes)
        guard mouse.device.category == .mouse, trackpad.device.category == .trackpad,
              available.contains(mouse.device), available.contains(trackpad.device)
        else { throw ToolError.invalid("Choose and verify both exact devices in LinearMouse first.") }
        if let smoothing, !smoothing.isFinite || !(0.2...1).contains(smoothing) {
            throw ToolError.invalid("Choose a smoothing strength from 0.2 to 1.")
        }

        let overlays = [overlay(mouse, smoothing: smoothing), overlay(trackpad, smoothing: nil)].compactMap { $0 }
        guard !overlays.isEmpty else { throw ToolError.invalid("Choose a direction or enable mouse-wheel smoothing.") }
        let encoded = try JSONSerialization.data(withJSONObject: overlays, options: [.sortedKeys])
        guard try matchingRanges(encoded, in: schemes).isEmpty else {
            throw ToolError.invalid("These scroll profiles already exist in LinearMouse.")
        }
        schemes.append(contentsOf: overlays)
        root["schemes"] = schemes
        let revised = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let journal = Journal(originalDigest: digest(original), overlays: encoded)
        let record = journalURL(for: config)
        try JSONEncoder().encode(journal).write(to: record, options: .atomic)
        do {
            try replace(config, expected: original, with: revised)
        } catch {
            try? FileManager.default.removeItem(at: record)
            throw error
        }
    }

    package static func restore(_ config: URL) throws {
        guard let managed = try loadJournal(for: config) else { return }
        let original = try read(config)
        if managed.originalDigest != digest(original) {
            var (root, schemes) = try document(original)
            schemes.removeSubrange(try managedRange(managed.overlays, in: schemes))
            root["schemes"] = schemes
            let revised = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try replace(config, expected: original, with: revised)
        }
        try FileManager.default.removeItem(at: journalURL(for: config))
    }

    private static func overlay(_ selection: Selection, smoothing: Double?) -> [String: Any]? {
        var scroll: [String: Any] = [:]
        if selection.direction != .inherit { scroll["reverse"] = ["vertical": selection.direction == .reverse] }
        if let smoothing {
            scroll["smoothed"] = ["vertical": [
                "enabled": true,
                "preset": "custom",
                "response": 1.10 - 0.8 * smoothing,
                "speed": 1,
                "acceleration": 1.0 + 0.4 * smoothing,
                "inertia": 0.25 + 0.45 * smoothing,
                "bouncing": false,
            ] as [String: Any]]
            scroll["distance"] = ["vertical": "auto"]
            scroll["acceleration"] = ["vertical": 1]
            scroll["speed"] = ["vertical": 0]
        }
        guard !scroll.isEmpty else { return nil }
        return ["if": ["device": selection.device.matcher], "scrolling": scroll]
    }

    private static func devices(from schemes: [[String: Any]]) -> [Device] {
        var result: Set<Device> = []
        for scheme in schemes {
            let predicates = (scheme["if"] as? [[String: Any]]) ?? (scheme["if"] as? [String: Any]).map { [$0] } ?? []
            for predicate in predicates {
                guard let fields = predicate["device"] as? [String: Any],
                      let category = (fields["category"] as? String).flatMap(Category.init)
                        ?? (fields["category"] as? [String]).flatMap({ $0.count == 1 ? Category(rawValue: $0[0]) : nil }),
                      let vendor = physicalID(fields["vendorID"]), let product = physicalID(fields["productID"])
                else { continue }
                let name = (fields["productName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let serial = (fields["serialNumber"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                guard name != nil || serial != nil else { continue }
                // LinearMouse documents that a receiver-wide match can affect multiple paired mice.
                if category == .mouse, vendor == 0x046d, [0xc52b, 0xc532, 0xc548].contains(product) { continue }
                result.insert(Device(category: category, vendor: vendor, product: product, name: name, serial: serial))
            }
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func physicalID(_ value: Any?) -> Int? {
        let number: Int?
        if let text = value as? String, text.lowercased().hasPrefix("0x") {
            number = Int(text.dropFirst(2), radix: 16)
        } else if let numeric = value as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID() {
            number = Int(exactly: numeric.doubleValue)
        } else {
            number = nil
        }
        return number.flatMap { (1...65_535).contains($0) ? $0 : nil }
    }

    private static func document(_ data: Data) throws -> ([String: Any], [[String: Any]]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemes = root["schemes"] as? [[String: Any]]
        else { throw ToolError.invalid("Choose a readable LinearMouse configuration with a schemes list.") }
        return (root, schemes)
    }

    private static func decodeOverlays(_ data: Data) throws -> [[String: Any]] {
        guard let schemes = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], (1...2).contains(schemes.count) else {
            throw ToolError.invalid("Could not verify the recorded scroll profiles.")
        }
        return schemes
    }

    private static func matchingRanges(_ data: Data, in schemes: [[String: Any]]) throws -> [Range<Int>] {
        let count = try decodeOverlays(data).count
        guard schemes.count >= count else { return [] }
        return (0...(schemes.count - count)).compactMap { start in
            let range = start..<(start + count)
            let candidate = try? JSONSerialization.data(withJSONObject: Array(schemes[range]), options: [.sortedKeys])
            return candidate == data ? range : nil
        }
    }

    private static func managedRange(_ data: Data, in schemes: [[String: Any]]) throws -> Range<Int> {
        let matching = try matchingRanges(data, in: schemes)
        guard matching.count == 1, let range = matching.first else {
            throw ToolError.invalid("LinearMouse changed these scroll profiles. Review them in LinearMouse before editing again.")
        }
        return range
    }

    private static func read(_ url: URL) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size <= 2_000_000
        else { throw ToolError.invalid("Choose a regular LinearMouse configuration under 2 MB.") }
        return try Data(contentsOf: url)
    }

    private static func replace(_ config: URL, expected: Data, with data: Data) throws {
        guard try read(config) == expected else {
            throw ToolError.invalid("LinearMouse settings changed during the update. Refresh and try again.")
        }
        try data.write(to: config, options: .atomic)
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private static func journalURL(for config: URL) -> URL {
        config.deletingLastPathComponent().appending(path: ".muk-scroll-profiles.json")
    }

    private static func loadJournal(for config: URL) throws -> Journal? {
        let url = journalURL(for: config)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Journal.self, from: read(url))
    }
}
