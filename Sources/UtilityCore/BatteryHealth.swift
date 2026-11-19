import Foundation
import IOKit.ps

public struct BatteryHealthSnapshot: Sendable {
    public struct InternalBattery: Sendable {
        public let charge: Int?
        public let isCharging: Bool?
        public let cycleCount: Int?
        public let designCapacity: Int?
        public let fullChargeCapacity: Int?
        public let remainingCapacity: Int?
        public let condition: String?
        public let maximumCapacity: Int?
    }

    public struct Accessory: Identifiable, Sendable {
        public let id: Int
        public let name: String
        public let battery: Int?
        public let left: Int?
        public let right: Int?
        public let caseCharge: Int?
    }

    public let powerSource: String?
    public let battery: InternalBattery?
    public let accessories: [Accessory]
    public let accessoryReadAvailable: Bool
}

public enum BatteryHealth {
    public static func snapshot() async throws -> BatteryHealthSnapshot {
        let native = nativePower()
        let registry = registryBattery()
        async let profile = commandOutput("/usr/sbin/system_profiler", name: "System Profiler",
            arguments: ["-json", "-timeout", "8", "SPPowerDataType", "SPBluetoothDataType"])
        async let accessories = accessoryPower()
        let (profileResult, accessoryResult) = try await (profile, accessories)
        try Task.checkCancellation()
        return assemble(power: native.source, internalSource: native.battery, registry: registry,
                        profile: profileResult.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] },
                        accessoryPower: accessoryResult)
    }

    static func assemble(
        power: String?, internalSource: [String: Any]?, registry: [String: Any]?, profile: [String: Any]?,
        accessoryPower: [AccessoryPower]? = nil
    ) -> BatteryHealthSnapshot {
        let powerEntries = profile?["SPPowerDataType"] as? [[String: Any]] ?? []
        let internalProfile = powerEntries.first { $0["_name"] as? String == "spbattery_information" }
        let batteryEntries = internalProfile.map { [$0] } ?? powerEntries
        let health = batteryEntries.compactMap { $0["sppower_battery_health_info"] as? [String: Any] }.first
        let chargeInfo = batteryEntries.compactMap { $0["sppower_battery_charge_info"] as? [String: Any] }.first
        let battery: BatteryHealthSnapshot.InternalBattery?
        if internalSource != nil || registry != nil || internalProfile != nil {
            let current = integer(internalSource?[kIOPSCurrentCapacityKey])
            let maximum = positive(internalSource?[kIOPSMaxCapacityKey])
            let charge: Int?
            if let current, let maximum, current <= maximum {
                charge = Int((Double(current) / Double(maximum) * 100).rounded())
            } else {
                charge = percent(chargeInfo?["sppower_battery_state_of_charge"])
            }
            let charging = internalSource?[kIOPSIsChargingKey] as? Bool ?? registry?["IsCharging"] as? Bool
                ?? profilerCharging(chargeInfo?["sppower_battery_is_charging"])
            let data = registry?["BatteryData"] as? [String: Any]
            let design = positive(registry?["DesignCapacity"]) ?? positive(data?["DesignCapacity"])
            let rawFull = positive(registry?["AppleRawMaxCapacity"]) ?? positive(data?["AppleRawMaxCapacity"])
                ?? positive(data?["FullChargeCapacity"])
            let rawRemaining = integer(registry?["AppleRawCurrentCapacity"]) ?? integer(data?["AppleRawCurrentCapacity"])
                ?? integer(data?["RemainingCapacity"])
            // Recent Macs expose percent-like CurrentCapacity/MaxCapacity
            // (0–100), while their raw keys and old mAh counters use charge units.
            let oldFull = positive(registry?["MaxCapacity"]).flatMap { $0 > 100 ? $0 : nil }
            let oldRemaining = oldFull == nil ? nil : integer(registry?["CurrentCapacity"])
            battery = .init(
                charge: charge, isCharging: charging, cycleCount: integer(registry?["CycleCount"])
                    ?? integer(health?["sppower_battery_cycle_count"]),
                designCapacity: design, fullChargeCapacity: rawFull ?? oldFull, remainingCapacity: rawRemaining ?? oldRemaining,
                condition: health?["sppower_battery_health"] as? String ?? internalSource?[kIOPSBatteryHealthKey] as? String,
                maximumCapacity: percent(health?["sppower_battery_health_maximum_capacity"])
            )
        } else {
            battery = nil
        }
        let wireless = profile?["SPBluetoothDataType"] as? [[String: Any]]
        var accessories: [BatteryHealthSnapshot.Accessory] = []
        let nativeByName = Dictionary(grouping: accessoryPower ?? [], by: \.name)
        for controller in wireless ?? [] {
            for item in controller["device_connected"] as? [[String: [String: Any]]] ?? [] {
                for (name, details) in item.sorted(by: { $0.key < $1.key }) {
                    accessories.append(.init(id: accessories.count, name: name,
                                             battery: percent(details["device_batteryLevelMain"] ?? details["device_batteryLevel"]),
                                             left: percent(details["device_batteryLevelLeft"]),
                                             right: percent(details["device_batteryLevelRight"]),
                                             caseCharge: percent(details["device_batteryLevelCase"])))
                }
            }
        }
        let profilerByName = Dictionary(grouping: accessories, by: \.name)
        accessories = accessories.map { listed in
            let readings = nativeByName[listed.name] ?? []
            guard profilerByName[listed.name]?.count == 1, readings.count == 1 else { return listed }
            return .init(id: listed.id, name: listed.name, battery: listed.battery ?? readings[0].charge,
                         left: listed.left, right: listed.right, caseCharge: listed.caseCharge)
        }
        for reading in accessoryPower ?? [] {
            if profilerByName[reading.name]?.count == 1, nativeByName[reading.name]?.count == 1 { continue }
            accessories.append(.init(id: accessories.count, name: reading.name, battery: reading.charge,
                                     left: nil, right: nil, caseCharge: nil))
        }
        return .init(powerSource: power, battery: battery, accessories: accessories,
                     accessoryReadAvailable: wireless != nil || accessoryPower != nil)
    }

    private static func profilerCharging(_ value: Any?) -> Bool? {
        switch value as? String {
        case "TRUE": true
        case "FALSE": false
        default: nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let exact = Int(exactly: number.doubleValue)
        return exact.flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func positive(_ value: Any?) -> Int? { integer(value).flatMap { $0 > 0 ? $0 : nil } }

    private static func percent(_ value: Any?) -> Int? {
        let parsed = integer(value) ?? (value as? String).flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "%"))))
        }
        return parsed.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    private static func nativePower() -> (source: String?, battery: [String: Any]?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (nil, nil) }
        let power = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            if let details = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
               details[kIOPSIsPresentKey] as? Bool != false {
                return (power, details)
            }
        }
        return (power, nil)
    }

    private static func registryBattery() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any],
              values["BatteryInstalled"] as? Bool != false else { return nil }
        return values
    }

    struct AccessoryPower: Equatable, Sendable {
        let name: String
        let charge: Int?
    }

    static func parseAccessoryPower(_ data: Data) -> [AccessoryPower]? {
        // pmset's upstream implementation writes names using MacRoman.
        guard let output = String(data: data, encoding: .macOSRoman),
              output.hasPrefix("Now drawing from ") else { return nil }
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].hasPrefix(" -"),
                  fields[1].hasSuffix(" present: true") else { return nil }
            let label = fields[0].dropFirst(2)
            let name = label[..<(label.range(of: #" \(id=-?[0-9]+\)$"#, options: .regularExpression)?.lowerBound ?? label.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.range(of: #"^InternalBattery-[0-9]+$"#, options: .regularExpression) == nil
            else { return nil }
            let value = fields[1].prefix(while: { $0.isASCII && $0.isNumber })
            let level = fields[1].dropFirst(value.count).hasPrefix("%;") ? percent(String(value)) : nil
            return AccessoryPower(name: name, charge: level)
        }
    }

    private static func accessoryPower() async throws -> [AccessoryPower]? {
        try await commandOutput("/usr/bin/pmset", name: "Power Management", arguments: ["-g", "accps"])
            .flatMap(parseAccessoryPower)
    }

    private static func commandOutput(_ path: String, name: String, arguments: [String]) async throws -> Data? {
        let folder = FileManager.default.temporaryDirectory.appending(path: ".MacUtilityKit-Battery-\(UUID().uuidString)")
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = folder.appending(path: "report")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            try await ExternalTool.run(URL(fileURLWithPath: path), name: name, arguments: arguments,
                                       directory: folder, standardOutput: handle)
            return try Data(contentsOf: output)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }
}
