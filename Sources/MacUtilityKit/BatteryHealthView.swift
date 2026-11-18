import SwiftUI
import UtilityCore

struct BatteryHealthView: View {
    @State private var snapshot: BatteryHealthSnapshot?
    @State private var refreshID = UUID()
    @State private var loading = true
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        InteractiveToolLayout(tool: .batteryHealth) { palette in
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .disabled(loading)
                Button("Copy Report", systemImage: "doc.on.doc") {
                    if let snapshot {
                        DeveloperToolFiles.copy(report(snapshot))
                        copied = true
                    }
                }
                .disabled(snapshot == nil || loading)
                if loading { ProgressView().controlSize(.small).accessibilityLabel("Reading battery information") }
                if copied { Text("Copied").foregroundStyle(.secondary).font(.callout) }
            }
            if let snapshot {
                WorkspaceSection("Power", palette: palette) {
                    row("Power source", snapshot.powerSource)
                    if let battery = snapshot.battery {
                        batteryRows(battery)
                    } else {
                        Text("No internal battery detected.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                WorkspaceSection("Connected accessories", palette: palette) {
                    if snapshot.accessories.isEmpty {
                        Text(snapshot.accessoryReadAvailable ? "No connected Bluetooth accessories." : "Accessory information is unavailable.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.accessories) { accessory in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(accessory.name).font(.callout.weight(.semibold))
                            Text(accessoryLevel(accessory)).font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }
        .task(id: refreshID) { await refresh() }
    }

    @ViewBuilder
    private func batteryRows(_ battery: BatteryHealthSnapshot.InternalBattery) -> some View {
        if let charge = battery.charge {
            ProgressView(value: Double(charge), total: 100)
                .accessibilityLabel("Battery charge")
        }
        ForEach(fields(battery), id: \.0) { label, value in row(label, value) }
    }

    private func fields(_ battery: BatteryHealthSnapshot.InternalBattery) -> [(String, String?)] {
        [
            ("Charge", percent(battery.charge)),
            ("Charging state", battery.isCharging.map { $0 ? "Charging" : "Not charging" }),
            ("Condition", battery.condition), ("Maximum capacity", percent(battery.maximumCapacity)),
            ("Cycle count", battery.cycleCount?.formatted()), ("Design capacity", capacity(battery.designCapacity)),
            ("Full charge capacity", capacity(battery.fullChargeCapacity)),
            ("Remaining capacity", capacity(battery.remainingCapacity))
        ]
    }

    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label, value: value ?? "Unavailable")
            .font(.callout.monospacedDigit())
    }

    private func percent(_ level: Int?) -> String? {
        level.map { (Double($0) / 100).formatted(.percent.precision(.fractionLength(0))) }
    }

    private func capacity(_ amount: Int?) -> String? { amount.map { "\($0.formatted()) mAh" } }

    private func accessoryLevel(_ accessory: BatteryHealthSnapshot.Accessory) -> String {
        let values = [percent(accessory.battery), percent(accessory.left).map { "Left \($0)" },
                      percent(accessory.right).map { "Right \($0)" }, percent(accessory.caseCharge).map { "Case \($0)" }]
            .compactMap { $0 }
        return values.isEmpty ? "Battery level unavailable" : values.joined(separator: " · ")
    }

    private func report(_ snapshot: BatteryHealthSnapshot) -> String {
        var lines = ["Mac Utility Kit Battery Health", "Power source: \(snapshot.powerSource ?? "Unavailable")"]
        if let battery = snapshot.battery {
            lines += fields(battery).map { "\($0.0): \($0.1 ?? "Unavailable")" }
        } else {
            lines.append("No internal battery detected.")
        }
        lines += ["", "Connected accessories"]
        if snapshot.accessories.isEmpty {
            lines.append(snapshot.accessoryReadAvailable ? "None" : "Unavailable")
        } else {
            lines += snapshot.accessories.map { "\($0.name): \(accessoryLevel($0))" }
        }
        return lines.joined(separator: "\n")
    }

    private func refresh() async {
        copied = false
        error = nil
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let result = try await BatteryHealth.snapshot()
            if !Task.isCancelled { snapshot = result }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
