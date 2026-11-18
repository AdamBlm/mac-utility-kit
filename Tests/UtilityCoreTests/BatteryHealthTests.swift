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
        let readings = try #require(BatteryHealth.parseAccessoryPower(encoded))
        #expect(readings.map(\.name) == ["Boîtier", "Headphones", "Trackpad", "Keyboard (id=custom)", "Mouse"])
        let profile: [String: Any] = ["SPBluetoothDataType": [["device_connected": [
            ["Headphones": ["device_batteryLevelMain": "91%", "device_batteryLevelLeft": "90%"]],
            ["Mouse": ["device_batteryLevelRight": "82%"]]
        ]]]]
        let first = BatteryHealth.assemble(power: nil, internalSource: nil, registry: nil, profile: profile,
                                           accessoryPower: readings)
        #expect(first.accessoryReadAvailable)
        #expect(first.battery == nil)
        #expect(first.accessories.count == 5)
        #expect(first.accessories.first { $0.name == "Headphones" }?.battery == 91)
        #expect(first.accessories.first { $0.name == "Headphones" }?.left == 90)
        #expect(first.accessories.first { $0.name == "Boîtier" }?.battery == 73)
        #expect(first.accessories.first { $0.name == "Trackpad" }?.battery == nil)

        #expect(first.accessories.first { $0.name == "Mouse" }?.battery == 84)
        #expect(first.accessories.first { $0.name == "Keyboard (id=custom)" }?.battery == 67)

        let empty = BatteryHealth.parseAccessoryPower(Data("Now drawing from 'AC Power'".utf8))
        let refreshed = BatteryHealth.assemble(power: nil, internalSource: nil, registry: nil, profile: nil,
                                               accessoryPower: empty)
        #expect(refreshed.accessoryReadAvailable)
        #expect(refreshed.accessories.isEmpty)
        #expect(BatteryHealth.parseAccessoryPower(Data("unexpected report".utf8)) == nil)
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
