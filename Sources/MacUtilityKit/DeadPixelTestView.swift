import AppKit
import SwiftUI
import UtilityCore

struct DeadPixelTestView: View {
    @State private var session = DeadPixelTestSession()
    @State private var displayID: UInt32?
    @State private var automatic = false
    @State private var interval = 3
    @State private var startingColor = DeadPixelColor.black

    var body: some View {
        InteractiveToolLayout(tool: .deadPixelTest) { palette in
            WorkspaceSection("Display test", palette: palette) {
                SettingRow("Display") {
                    Picker("Display", selection: $displayID) {
                        if displayID == nil { Text("No display selected").tag(UInt32?.none) }
                        ForEach(session.displays) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }
                SettingRow("Starting color") {
                    Picker("Starting color", selection: $startingColor) {
                        ForEach(DeadPixelColor.allCases, id: \.self) { color in
                            Text(color.rawValue.capitalized).tag(color)
                        }
                    }
                    .labelsHidden()
                }
                Toggle("Automatically cycle colors", isOn: $automatic)
                if automatic {
                    SettingRow("Interval") {
                        Picker("Interval", selection: $interval) {
                            ForEach([2, 3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                Text(automatic
                     ? "Use the arrow keys to step, 1–5 to jump to a color, Space to pause or resume, and Escape to exit."
                     : "Use the arrow keys or click to step through colors, 1–5 to jump, and Escape to exit.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Start Test", systemImage: "display") {
                    if let displayID {
                        session.start(displayID: displayID, automatically: automatic,
                                      interval: interval, startingColor: startingColor)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayID == nil || session.active)
                if let issue = session.issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.finish()
        }
        .onDisappear { session.finish() }
    }

    private func refresh() {
        session.refreshDisplays()
        if !session.displays.contains(where: { $0.id == displayID }) { displayID = session.displays.first?.id }
    }
}
