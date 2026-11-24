import AppKit
import SwiftUI
import UtilityCore

struct MouseFixesView: View {
    @State private var config: URL?
    @State private var app: URL?
    @State private var engineVersion: String?
    @State private var running = false
    @State private var snapshot: MouseFixes.Snapshot?
    @State private var mouse: MouseFixes.Device?
    @State private var trackpad: MouseFixes.Device?
    @State private var mouseDirection = MouseFixes.Direction.inherit
    @State private var trackpadDirection = MouseFixes.Direction.inherit
    @State private var smooth = false
    @State private var strength = 0.5
    @State private var verified = false
    @State private var issue: String?

    private static let engineID = "com.lujjjh.LinearMouse"

    private var engineSupported: Bool {
        guard let version = engineVersion else { return false }
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        return parts.count == 2 && parts[0] == 0 && parts[1] >= 12
    }

    private var applied: Bool { snapshot?.applied == true }

    var body: some View {
        InteractiveToolLayout(tool: .mouseFixes) { palette in
            WorkspaceSection("LinearMouse", palette: palette) {
                if let engineVersion {
                    Text("LinearMouse \(engineVersion) · \(running ? "Running" : "Closed")")
                        .font(.headline)
                } else {
                    Text("Install LinearMouse to use separate scroll settings.").font(.headline)
                }
                Text("LinearMouse needs Accessibility access to apply these profiles. macOS shows its permission in System Settings.")
                    .foregroundStyle(.secondary)
                WorkspaceFlowLayout {
                    if let app {
                        Button("Open LinearMouse", systemImage: "cursorarrow") { NSWorkspace.shared.open(app) }
                    } else {
                        Link("Get LinearMouse", destination: URL(string: "https://linearmouse.app")!)
                    }
                    Button("Open Accessibility Settings", systemImage: "gearshape") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                }
                if app != nil, !engineSupported {
                    Text("Use LinearMouse 0.12 or later in the 0.x series for this configuration format.")
                        .foregroundStyle(.secondary)
                }
                if let issue { Text(issue).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let snapshot {
                WorkspaceSection("Devices", palette: palette) {
                    if !snapshot.devices.contains(where: { $0.category == .mouse })
                        || !snapshot.devices.contains(where: { $0.category == .trackpad }) {
                        Text("Select each physical device in LinearMouse, save a per-device setting there, then refresh.")
                            .foregroundStyle(.secondary)
                    }
                    devicePicker("Mouse", category: .mouse, selection: $mouse)
                    devicePicker("Trackpad", category: .trackpad, selection: $trackpad)
                    Toggle("I verified both device identities in LinearMouse", isOn: $verified)
                        .disabled(mouse == nil || trackpad == nil || applied)
                    Text("Choose physical devices rather than shared receivers. Identical devices without a unique serial number can share a profile.")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: mouse) { verified = false }
                .onChange(of: trackpad) { verified = false }

                WorkspaceSection("Scrolling", palette: palette) {
                    if applied {
                        Text("Mouse Fixes profiles are saved in LinearMouse.").font(.headline)
                        HStack {
                            Button("Pause profiles") { restore(reset: false) }
                            Button("Restore previous settings") { restore(reset: true) }
                        }
                    } else {
                        Picker("Mouse scroll direction", selection: $mouseDirection) { directionChoices }
                        Picker("Trackpad scroll direction", selection: $trackpadDirection) { directionChoices }
                        Toggle("Smooth vertical mouse-wheel scrolling", isOn: $smooth)
                        if smooth {
                            Slider(value: $strength, in: 0.2...1) { Text("Smoothing strength") }
                        }
                        Text("Both direction settings apply to vertical scrolling.")
                            .foregroundStyle(.secondary)
                        Button("Apply Profiles", action: apply)
                            .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                            .disabled(!engineSupported || !verified || mouse == nil || trackpad == nil
                                      || (!smooth && mouseDirection == .inherit && trackpadDirection == .inherit))
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var directionChoices: some View {
        ForEach(MouseFixes.Direction.allCases, id: \.self) { direction in
            Text(direction.rawValue).tag(direction)
        }
    }

    private func devicePicker(_ title: String, category: MouseFixes.Category, selection: Binding<MouseFixes.Device?>) -> some View {
        Picker(title, selection: selection) {
            Text("Choose a device").tag(MouseFixes.Device?.none)
            ForEach(snapshot?.devices.filter { $0.category == category } ?? []) { device in
                Text(device.title).tag(Optional(device))
            }
        }
        .disabled(applied)
    }

    private func refresh() {
        let manager = FileManager.default
        app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.engineID)
        engineVersion = app.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.engineID).isEmpty
        var paths = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .prefix(1).map { $0.appending(path: "linearmouse/linearmouse.json") }
        paths.append(manager.homeDirectoryForCurrentUser.appending(path: ".config/linearmouse/linearmouse.json"))
        config = paths.first { manager.fileExists(atPath: $0.path) }
        guard let config else {
            snapshot = nil
            issue = app == nil ? nil : "Open LinearMouse once to create its configuration."
            return
        }
        do {
            let update = try MouseFixes.inspect(config)
            if let mouse, !update.devices.contains(mouse) { self.mouse = nil }
            if let trackpad, !update.devices.contains(trackpad) { self.trackpad = nil }
            snapshot = update
            issue = nil
        } catch {
            snapshot = nil
            issue = error.localizedDescription
        }
    }

    private func apply() {
        guard let config, let mouse, let trackpad, engineSupported, verified else { return }
        do {
            try MouseFixes.apply(config, mouse: .init(device: mouse, direction: mouseDirection),
                                 trackpad: .init(device: trackpad, direction: trackpadDirection),
                                 smoothing: smooth ? strength : nil)
            refresh()
        } catch {
            issue = error.localizedDescription
        }
    }

    private func restore(reset: Bool) {
        guard let config else { return }
        do {
            try MouseFixes.restore(config)
            if reset {
                mouseDirection = .inherit
                trackpadDirection = .inherit
                smooth = false
                strength = 0.5
                verified = false
            }
            refresh()
        } catch {
            issue = error.localizedDescription
        }
    }
}
