import SwiftUI
import UtilityCore

struct HiddenSettingsView: View {
    @State private var current: [HiddenSetting: HiddenSettingValue] = [:]
    @State private var proposed: [HiddenSetting: HiddenSettingValue] = [:]
    @State private var confirmation: HiddenSetting?
    @State private var message: String?

    var body: some View {
        InteractiveToolLayout(tool: .hiddenSettings) { palette in
            WorkspaceSection("Preferences", palette: palette) {
                Button("Refresh", systemImage: "arrow.clockwise", action: reload)
                Text("Finder, Dock, or an affected app may need to relaunch before a saved setting takes effect.")
                    .font(.callout).foregroundStyle(.secondary)
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            ForEach(HiddenSetting.Application.allCases) { application in
                WorkspaceSection(application.rawValue, palette: palette) {
                    ForEach(HiddenSetting.allCases.filter { $0.application == application }) { setting in
                        let value = current[setting, default: .unavailable]
                        VStack(alignment: .leading, spacing: 5) {
                            Text(setting.title).font(.headline)
                            Text(setting.effect).font(.callout).foregroundStyle(.secondary)
                            LabeledContent("Saved value", value: value.rawValue)
                            if value == .hostOverride {
                                Text("A setting specific to this Mac takes priority here.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if value.canChange {
                                HStack {
                                    Picker("New value", selection: Binding(
                                        get: { proposed[setting, default: value] },
                                        set: { proposed[setting] = $0 }
                                    )) {
                                        Text(HiddenSettingValue.enabled.rawValue).tag(HiddenSettingValue.enabled)
                                        Text(HiddenSettingValue.disabled.rawValue).tag(HiddenSettingValue.disabled)
                                        Text(HiddenSettingValue.systemDefault.rawValue).tag(HiddenSettingValue.systemDefault)
                                    }
                                    .labelsHidden()
                                    Button("Apply…") { confirmation = setting }
                                        .disabled(proposed[setting, default: value] == value)
                                    if value != .systemDefault {
                                        Button("Reset…") {
                                            proposed[setting] = .systemDefault
                                            confirmation = setting
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { reload() }
        .confirmationDialog("Apply preference?", isPresented: Binding(get: { confirmation != nil }, set: { shown in
            if !shown { confirmation = nil }
        }), titleVisibility: .visible, presenting: confirmation) { setting in
            Button("Apply") { apply(setting) }
        } message: { setting in
            Text("\(setting.title) · \(proposed[setting, default: .systemDefault].rawValue)")
        }
    }

    private func reload() {
        current = Dictionary(uniqueKeysWithValues: HiddenSetting.allCases.map { ($0, HiddenSettings.read($0)) })
        proposed = [:]
        message = nil
    }

    private func apply(_ setting: HiddenSetting) {
        guard let value = proposed[setting], let existing = current[setting] else { return }
        do {
            try HiddenSettings.apply(value, to: setting, expecting: existing)
            current[setting] = HiddenSettings.read(setting)
            proposed[setting] = nil
            let app = setting.application == .macOS ? "Finder" : setting.application.rawValue
            message = "Saved \(setting.title). Relaunch \(app) if the change does not appear."
        } catch {
            current[setting] = HiddenSettings.read(setting)
            proposed[setting] = nil
            message = error.localizedDescription
        }
    }
}
