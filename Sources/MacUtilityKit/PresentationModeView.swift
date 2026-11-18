import SwiftUI

struct PresentationModeView: View {
    let controller: PresentationModeController
    @State private var hideDesktop = true
    @State private var hideDock = false
    @State private var keepAwake = true
    @State private var minutes: Int?

    var body: some View {
        InteractiveToolLayout(tool: .presentationMode) { palette in
            WorkspaceSection("Session", palette: palette) {
                if controller.isActive {
                    Label("Presentation Mode is active", systemImage: "play.rectangle")
                        .font(.headline)
                    if let deadline = controller.deadline {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let remaining = ContinuousClock.now.duration(to: deadline).components
                            let seconds = max(0, remaining.seconds + (remaining.attoseconds > 0 ? 1 : 0))
                            Text(Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond)))
                                .monospacedDigit().accessibilityLabel("Time remaining")
                        }
                    } else {
                        Text("Runs until stopped.").foregroundStyle(.secondary)
                    }
                    if controller.hidesDesktop { Text("Desktop items hidden").foregroundStyle(.secondary) }
                    if controller.hidesDock { Text("Dock auto-hide enabled").foregroundStyle(.secondary) }
                    if controller.keepsAwake { Text("Idle sleep prevention active").foregroundStyle(.secondary) }
                    Button("Stop", systemImage: "stop.fill") { controller.stop() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Toggle("Hide desktop items", isOn: $hideDesktop)
                    if hideDesktop {
                        Text("A neutral background covers desktop items behind open windows.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Toggle("Auto-hide Dock", isOn: $hideDock)
                    if hideDock {
                        Text("The Dock briefly reloads when its auto-hide setting changes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Toggle("Keep the Mac and display awake", isOn: $keepAwake)
                    SettingRow("Duration") {
                        Picker("Duration", selection: $minutes) {
                            Text("Until stopped").tag(Int?.none)
                            ForEach([15, 30, 60, 120], id: \.self) {
                                Text("\($0) minutes").tag(Optional($0))
                            }
                        }
                        .labelsHidden()
                    }
                    Button("Start", systemImage: "play.fill") {
                        controller.start(hideDesktop: hideDesktop, hideDock: hideDock, keepAwake: keepAwake, minutes: minutes)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(hideDesktop || hideDock || keepAwake) || (hideDock && controller.needsRecovery))
                }
                if let issue = controller.issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
                if controller.needsRecovery, !controller.isActive {
                    Button("Retry Dock Restoration") { controller.recover() }
                }
            }
        }
    }
}
