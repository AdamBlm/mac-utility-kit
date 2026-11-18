import AppKit
import SwiftUI
import UtilityCore

struct CleanKeyboardView: View {
    @State private var input: CleanKeyboardInput
    @State private var session: KeyboardCleaningSession
    @State private var dimmer = CleaningDisplayDimmer()
    @State private var seconds = 30
    @State private var dimScreen = false
    @State private var hasPermission = false

    init() {
        let input = CleanKeyboardInput()
        _input = State(initialValue: input)
        _session = State(initialValue: KeyboardCleaningSession(input: input))
    }

    var body: some View {
        InteractiveToolLayout(tool: .cleanKeyboard) { palette in
            WorkspaceSection("Keyboard pause", palette: palette) {
                Text("Pause typing while you clean. The mouse and trackpad stay available, and hardware keys such as Power still work.")
                    .foregroundStyle(.secondary)
                if session.active {
                    Text("Time remaining: \(session.remainingSeconds) s")
                        .font(.title2.monospacedDigit())
                    Button("Stop Cleaning", systemImage: "stop.circle.fill") {
                        finish(message: "Keyboard input restored.")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Picker("Duration", selection: $seconds) {
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("60 seconds").tag(60)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Dim displays during cleaning", isOn: $dimScreen)
                    HStack {
                        if hasPermission {
                            Button("Start Cleaning", systemImage: "keyboard") {
                                session.start(seconds: seconds)
                                if session.active && dimScreen { dimmer.show() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Request Accessibility Access", action: input.requestPermission)
                            Button("Open Accessibility Settings", systemImage: "gearshape", action: openAccessibility)
                        }
                    }
                    if !hasPermission {
                        Text("Accessibility access lets macOS temporarily suppress typing during a cleaning session.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let status = session.status {
                    Text(status).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .onAppear { hasPermission = input.hasPermission }
        .onDisappear { finish() }
        .onChange(of: session.active) { _, active in
            if !active { dimmer.hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = input.hasPermission
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in finish() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in finish() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in finish() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in finish() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in finish() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in finish() }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name("com.apple.screenIsLocked")
        )) { _ in finish() }
    }

    private func finish(message: String? = nil) {
        session.stop(message: message)
        dimmer.hide()
    }

    private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class CleaningDisplayDimmer {
    private var panels: [NSPanel] = []

    func show() {
        hide()
        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false, screen: screen)
            panel.setFrame(screen.frame, display: false)
            panel.backgroundColor = .black
            panel.isOpaque = false
            panel.alphaValue = 0.42
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.orderFrontRegardless()
            return panel
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}
