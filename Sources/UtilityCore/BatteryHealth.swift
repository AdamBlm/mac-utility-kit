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
        let profile = try await systemProfile()
        try Task.checkCancellation()
        return assemble(power: native.source, internalSource: native.battery, registry: registry, profile: profile)
    }

    static func assemble(
        power: String?, internalSource: [String: Any]?, registry: [String: Any]?, profile: [String: Any]?
    ) -> BatteryHealthSnapshot {
        let powerEntries = profile?["SPPowerDataType"] as? [[String: Any]] ?? []
        let health = powerEntries.compactMap { $0["sppower_battery_health_info"] as? [String: Any] }.first
        let chargeInfo = powerEntries.compactMap { $0["sppower_battery_charge_info"] as? [String: Any] }.first
        let battery: BatteryHealthSnapshot.InternalBattery?
        if internalSource != nil || registry != nil {
            let current = integer(internalSource?[kIOPSCurrentCapacityKey])
            let maximum = positive(internalSource?[kIOPSMaxCapacityKey])
            let charge: Int?
            if let current, let maximum, current <= maximum {
                charge = Int((Double(current) / Double(maximum) * 100).rounded())
            } else {
                charge = percent(chargeInfo?["sppower_battery_state_of_charge"])
            }
            let charging = internalSource?[kIOPSIsChargingKey] as? Bool ?? registry?["IsCharging"] as? Bool
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
        return .init(powerSource: power, battery: battery, accessories: accessories, accessoryReadAvailable: wireless != nil)
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

    private static func systemProfile() async throws -> [String: Any]? {
        let folder = FileManager.default.temporaryDirectory.appending(path: ".MacUtilityKit-Battery-\(UUID().uuidString)")
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = folder.appending(path: "power.json")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            try await ExternalTool.run(URL(fileURLWithPath: "/usr/sbin/system_profiler"), name: "System Profiler",
                                       arguments: ["-json", "-timeout", "8", "SPPowerDataType", "SPBluetoothDataType"],
                                       directory: folder, standardOutput: handle)
            return try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }
}
