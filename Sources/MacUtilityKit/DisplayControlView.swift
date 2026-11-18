import AppKit
import SwiftUI
import UtilityCore

struct DisplayControlDraft {
    var executable: URL?
    var selectedID: UUID?
}

struct DisplayControlView: View {
    @Binding var draft: DisplayControlDraft
    @State private var engine: DisplayControl?
    @State private var displays: [DisplayControl.Display] = []
    @State private var settings: [DisplayControl.Feature: DisplayControl.Setting] = [:]
    @State private var proposed: [DisplayControl.Feature: Int] = [:]
    @State private var operation: Task<Void, Never>?
    @State private var needsRefresh = false
    @State private var issue: String?
    @State private var status: String?

    var body: some View {
        InteractiveToolLayout(tool: .displayControl) { palette in
            if DisplayControl.platformSupported {
                WorkspaceSection("Connection", palette: palette) {
                    HStack {
                        Button("Choose m1ddc…", systemImage: "folder", action: choose)
                            .disabled(operation != nil)
                        if let executable = draft.executable {
                            Text(executable.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text("Install m1ddc to query compatible external displays.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                            .disabled(engine == nil || operation != nil)
                    }
                    if !displays.isEmpty {
                        SettingRow("Display") {
                            Picker("Display", selection: selection) {
                                Text("Choose an external display").tag(UUID?.none)
                                ForEach(displays) { display in
                                    Text(displayLabel(display)).tag(Optional(display.id))
                                }
                            }
                            .labelsHidden()
                            .disabled(operation != nil)
                        }
                    } else if engine != nil, operation == nil, issue == nil {
                        Text("No external displays were found through m1ddc.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let display = selectedDisplay {
                    WorkspaceSection("Controls", palette: palette) {
                        ForEach(DisplayControl.Feature.allCases) { feature in
                            control(feature, display: display)
                        }
                        Text("Availability depends on the monitor, cable, and DDC/CI settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if operation != nil { ProgressView("Contacting Display…").controlSize(.small) }
                if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.callout) }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
            } else {
                WorkspaceSection("Connection", palette: palette) {
                    Text("The m1ddc hardware backend requires an Apple Silicon Mac.").font(.callout)
                }
            }
        }
        .onAppear(perform: open)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            if operation != nil {
                needsRefresh = true
            } else if engine != nil {
                refresh()
            }
        }
        .onDisappear {
            needsRefresh = false
            operation?.cancel()
        }
    }

    private var selectedDisplay: DisplayControl.Display? { displays.first { $0.id == draft.selectedID } }

    private func displayLabel(_ display: DisplayControl.Display) -> String {
        if displays.filter({ $0.name == display.name }).count > 1 {
            return "\(display.name) · Display \(display.displayID)"
        }
        return display.name
    }

    private var selection: Binding<UUID?> {
        Binding(get: { draft.selectedID }, set: { id in
            draft.selectedID = id
            loadSettings()
        })
    }

    @ViewBuilder
    private func control(_ feature: DisplayControl.Feature, display: DisplayControl.Display) -> some View {
        SettingRow(feature.rawValue) {
            if let setting = settings[feature] {
                HStack(spacing: 12) {
                    Slider(value: Binding(get: { Double(proposed[feature] ?? setting.current) },
                                          set: { proposed[feature] = Int($0.rounded()) }),
                           in: 0...Double(setting.maximum), step: 1)
                        .accessibilityLabel(feature.rawValue)
                    Text("\(proposed[feature] ?? setting.current) / \(setting.maximum)")
                        .font(.callout.monospacedDigit())
                        .fixedSize()
                    Button("Apply") { apply(feature, display: display) }
                        .disabled(proposed[feature] == setting.current)
                        .accessibilityLabel("Apply \(feature.rawValue.lowercased())")
                }
                .disabled(operation != nil)
                .help("Current monitor value \(setting.current). Supported range 0 to \(setting.maximum).")
                Text("Current \(setting.current) · Range 0–\(setting.maximum)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(operation == nil ? "Unavailable" : "Checking…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func open() {
        guard DisplayControl.platformSupported, operation == nil else { return }
        if draft.executable == nil {
            draft.executable = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                .map(URL.init(fileURLWithPath:))
        }
        engine = draft.executable.map { DisplayControl(executable: $0) }
        if engine != nil { refresh() }
    }

    private func choose() {
        guard let executable = DeveloperToolFiles.choose() else { return }
        draft.executable = executable
        draft.selectedID = nil
        engine = DisplayControl(executable: executable)
        refresh()
    }

    private func refresh() {
        guard let engine, operation == nil else { return }
        clearFeedback()
        settings = [:]
        proposed = [:]
        operation = Task {
            defer { finishOperation() }
            do {
                let available = try await engine.displays()
                try Task.checkCancellation()
                displays = available
                if selectedDisplay == nil { draft.selectedID = available.count == 1 ? available.first?.id : nil }
                if let display = selectedDisplay {
                    let current = try await engine.settings(for: display)
                    try Task.checkCancellation()
                    show(current)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    private func loadSettings() {
        settings = [:]
        proposed = [:]
        clearFeedback()
        guard let engine, let display = selectedDisplay, operation == nil else { return }
        operation = Task {
            defer { finishOperation() }
            do {
                let current = try await engine.settings(for: display)
                try Task.checkCancellation()
                show(current)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    private func show(_ current: [DisplayControl.Feature: DisplayControl.Setting]) {
        settings = current
        proposed = current.mapValues(\.current)
    }

    private func apply(_ feature: DisplayControl.Feature, display: DisplayControl.Display) {
        guard let engine, let value = proposed[feature], operation == nil else { return }
        clearFeedback()
        operation = Task {
            defer { finishOperation() }
            do {
                let result = try await engine.apply(value, feature: feature, on: display)
                try Task.checkCancellation()
                switch result {
                case .accepted(let actual):
                    settings[feature] = actual
                    proposed[feature] = actual.current
                    status = "\(display.name) reports \(feature.rawValue.lowercased()) at \(actual.current)."
                case .notAccepted(let actual):
                    settings[feature] = actual
                    proposed[feature] = actual.current
                    issue = "Requested \(value). The display reports \(actual.current)."
                case .unconfirmed:
                    settings[feature] = nil
                    proposed[feature] = nil
                    issue = "Could not read back the setting. Refresh before making another adjustment."
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    settings[feature] = nil
                    proposed[feature] = nil
                    issue = error.localizedDescription
                }
            }
        }
    }

    private func clearFeedback() {
        issue = nil
        status = nil
    }

    private func finishOperation() {
        operation = nil
        if needsRefresh {
            needsRefresh = false
            refresh()
        }
    }
}
