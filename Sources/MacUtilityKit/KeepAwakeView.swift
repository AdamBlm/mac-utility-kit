import SwiftUI

struct KeepAwakeView: View {
    let controller: KeepAwakeController
    @State private var duration: DurationOption = .thirty
    @State private var customMinutes = "45"
    @State private var keepDisplayAwake = false

    private enum DurationOption: String, CaseIterable {
        case fifteen = "15 minutes"
        case thirty = "30 minutes"
        case hour = "1 hour"
        case twoHours = "2 hours"
        case custom = "Custom"
        case indefinite = "Until stopped"
    }

    private var minutes: Int? {
        switch duration {
        case .fifteen: 15
        case .thirty: 30
        case .hour: 60
        case .twoHours: 120
        case .custom: Int(customMinutes).flatMap { KeepAwakeController.supportedMinutes.contains($0) ? $0 : nil }
        case .indefinite: nil
        }
    }

    var body: some View {
        InteractiveToolLayout(tool: .keepAwake) { palette in
            WorkspaceSection("Session", palette: palette) {
                if controller.isActive {
                    Label("Idle sleep prevention is active", systemImage: "moon.zzz")
                        .font(.headline)
                    if controller.keepsDisplayAwake {
                        Text("The display stays awake during this session.")
                            .foregroundStyle(.secondary)
                    }
                    if let deadline = controller.deadline {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let remaining = ContinuousClock.now.duration(to: deadline).components
                            let seconds = max(0, remaining.seconds + (remaining.attoseconds > 0 ? 1 : 0))
                            Text(Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond)))
                                .monospacedDigit()
                                .accessibilityLabel("Time remaining: \(seconds) seconds")
                        }
                    } else {
                        Text("Runs until you stop the session or quit the app.")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Stop", systemImage: "stop.fill") { controller.stop() }
                        if controller.deadline != nil {
                            Button("Add 15 Minutes", systemImage: "clock.badge.plus") { controller.extend(minutes: 15) }
                        }
                    }
                } else {
                    SettingRow("Duration") {
                        Picker("Duration", selection: $duration) {
                            ForEach(DurationOption.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                    }
                    if duration == .custom {
                        SettingRow("Custom duration") {
                            TextField("Minutes", text: $customMinutes)
                                .frame(width: 88)
                            Text("minutes").foregroundStyle(.secondary)
                        }
                        if minutes == nil {
                            Text(KeepAwakeController.invalidDurationMessage)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Keep the display awake", isOn: $keepDisplayAwake)
                    Button("Start", systemImage: "play.fill") {
                        controller.start(minutes: minutes, keepDisplayAwake: keepDisplayAwake)
                    }
                    .disabled(duration != .indefinite && minutes == nil)
                }
                if let error = controller.error { Text(error).font(.callout).foregroundStyle(.red) }
                Text("This prevents idle sleep. Closing the lid, choosing Sleep, or system power policy can still put your Mac to sleep.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
