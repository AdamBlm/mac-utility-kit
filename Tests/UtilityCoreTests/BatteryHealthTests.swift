import Foundation
import Testing
@testable import UtilityCore

struct BatteryHealthTests {
    @Test func separatesChargePercentAndCapacityAndIgnoresDisconnectedAccessories() throws {
        let profile: [String: Any] = [
            "SPPowerDataType": [["sppower_battery_health_info": [
                "sppower_battery_health": "Good", "sppower_battery_health_maximum_capacity": "97\u{00A0}%"
            ]]],
            "SPBluetoothDataType": [[
                "device_connected": [["Headphones": ["device_batteryLevelLeft": "55\u{00A0}%", "device_batteryLevelRight": "62 %"]]],
                "device_not_connected": [["Old keyboard": ["device_batteryLevelMain": "99%"]]]
            ]]
        ]
        let power = BatteryHealth.assemble(power: "AC Power", internalSource: ["Current Capacity": 80, "Max Capacity": 100],
            registry: ["CycleCount": 25, "MaxCapacity": 100,
                       "BatteryData": ["DesignCapacity": 6_400, "AppleRawMaxCapacity": 6_200, "AppleRawCurrentCapacity": 4_200]],
            profile: profile)
        let battery = try #require(power.battery)
        #expect(battery.charge == 80)
        #expect(battery.designCapacity == 6_400)
        #expect(battery.fullChargeCapacity == 6_200)
        #expect(battery.remainingCapacity == 4_200)
        #expect(battery.cycleCount == 25)
        #expect(battery.maximumCapacity == 97)
        #expect(power.accessories.count == 1)
        #expect(power.accessories.first?.left == 55)
        #expect(power.accessories.first?.right == 62)
        let afterDisconnect = BatteryHealth.assemble(power: nil, internalSource: nil, registry: nil,
            profile: ["SPBluetoothDataType": [["device_not_connected": [["Headphones": ["device_batteryLevelLeft": "55%"]]]]]])
        #expect(afterDisconnect.accessories.isEmpty)
        #expect(afterDisconnect.accessoryReadAvailable)
    }

    @Test func readsNativeAccessoryPowerAndRetainsProfilerDetails() throws {
        let output = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=100)\t80%; AC attached; not charging present: true
         -Boîtier (id=101)\t73%; charging; 0:00 remaining present: true
         -Headphones (id=102)\t96%; charging; 0:00 remaining present: true
         -Old keyboard (id=103)\t99%; discharging; 0:00 remaining present: false
         -Trackpad (id=104)\tcharged present: true
         -Keyboard (id=custom)\t67%; discharging present: true
         -Mouse (id=-105)\t84%; discharging present: true
        """
        let encoded = try #require(output.data(using: .macOSRoman))
        let managed = try #require(BatteryHealth.parsePowerManagementReport(encoded))
        let readings = managed.accessories
        #expect(managed.source == "AC Power")
        #expect(readings.map(\.name) == ["Boîtier", "Headphones", "Trackpad", "Keyboard (id=custom)", "Mouse"])
        let profile: [String: Any] = ["SPBluetoothDataType": [["device_connected": [
            ["Headphones": ["device_batteryLevelMain": "91%", "device_batteryLevelLeft": "90%"]],
            ["Mouse": ["device_batteryLevelRight": "82%"]],
            ["Keyboard": ["device_batteryLevelMain": "Unavailable", "device_batteryLevel": "63%"]]
        ]]]]
        let first = BatteryHealth.assemble(power: nil, internalSource: nil, registry: nil, profile: profile,
                                           managedPower: managed)
        #expect(first.accessoryReadAvailable)
        #expect(first.powerSource == "AC Power")
        #expect(first.battery == nil)
        #expect(first.accessories.count == 6)
        #expect(first.accessories.first { $0.name == "Headphones" }?.battery == 91)
        #expect(first.accessories.first { $0.name == "Headphones" }?.left == 90)
        #expect(first.accessories.first { $0.name == "Boîtier" }?.battery == 73)
        #expect(first.accessories.first { $0.name == "Trackpad" }?.battery == nil)

        #expect(first.accessories.first { $0.name == "Mouse" }?.battery == 84)
        #expect(first.accessories.first { $0.name == "Keyboard (id=custom)" }?.battery == 67)
        #expect(first.accessories.first { $0.name == "Keyboard" }?.battery == 63)

        let empty = BatteryHealth.parsePowerManagementReport(Data("Now drawing from 'AC Power'".utf8))
        let refreshed = BatteryHealth.assemble(power: "Battery Power", internalSource: nil, registry: nil, profile: nil,
                                               managedPower: empty)
        #expect(refreshed.accessoryReadAvailable)
        #expect(refreshed.powerSource == "Battery Power")
        #expect(refreshed.accessories.isEmpty)
        #expect(BatteryHealth.parsePowerManagementReport(Data("unexpected report".utf8)) == nil)
    }

    @Test func fallsBackToSystemProfilerInternalBatteryAndRespectsNativeChargingState() throws {
        let internalProfile: [String: Any] = [
            "_name": "spbattery_information",
            "sppower_battery_charge_info": ["sppower_battery_state_of_charge": 62, "sppower_battery_is_charging": "FALSE"],
            "sppower_battery_health_info": ["sppower_battery_cycle_count": 10, "sppower_battery_health": "Good"]
        ]
        let chargerProfile = ["_name": "spaccharger_information", "sppower_battery_is_charging": "TRUE"]
        let profile = ["SPPowerDataType": [chargerProfile, internalProfile]]
        let fallback = BatteryHealth.assemble(power: nil, internalSource: nil, registry: nil, profile: profile)
        let battery = try #require(fallback.battery)
        #expect(battery.charge == 62)
        #expect(battery.isCharging == false)
        #expect(battery.cycleCount == 10)
        #expect(battery.condition == "Good")
        #expect(battery.designCapacity == nil)

        let native = BatteryHealth.assemble(power: nil, internalSource: ["Is Charging": true], registry: nil, profile: profile)
        #expect(native.battery?.isCharging == true)
        let desktop = BatteryHealth.assemble(power: nil, internalSource: nil, registry: nil,
                                            profile: ["SPPowerDataType": [chargerProfile]])
        #expect(desktop.battery == nil)
    }

    @Test func distinguishesMissingBatteryAndUnreportedFields() throws {
        let desktop = BatteryHealth.assemble(power: "AC Power", internalSource: nil, registry: nil, profile: nil)
        #expect(desktop.battery == nil)
        #expect(!desktop.accessoryReadAvailable)
        let partial = BatteryHealth.assemble(power: nil, internalSource: ["Current Capacity": 1_000, "Max Capacity": 2_000],
            registry: ["CycleCount": false, "CurrentCapacity": 50, "MaxCapacity": 100], profile: nil)
        let battery = try #require(partial.battery)
        #expect(battery.charge == 50)
        #expect(battery.fullChargeCapacity == nil)
        #expect(battery.remainingCapacity == nil)
        #expect(battery.cycleCount == nil)
    }
}
