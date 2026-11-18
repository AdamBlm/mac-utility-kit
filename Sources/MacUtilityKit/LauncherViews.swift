import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import UtilityCore

struct LauncherMenu: View {
    let controller: LauncherController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Find a tool…") {
            controller.attach(openWindow: openWindow)
            controller.showLauncher()
        }
        Button("Open Mac Utility Kit") {
            controller.attach(openWindow: openWindow)
            controller.showWorkspace()
        }
        Divider()
        SettingsLink()
        Button("Quit Mac Utility Kit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct LauncherSettingsView: View {
    @Bindable var controller: LauncherController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show Mac Utility Kit in the menu bar", isOn: $controller.menuBarEnabled)
                Toggle("Hide Dock icon", isOn: $controller.hideDockIcon)
                    .disabled(!controller.menuBarEnabled)
            }
            Section("Tool launcher") {
                KeyboardShortcuts.Recorder("Global shortcut", name: .toolLauncher)
                Text("Use the shortcut from any app while Mac Utility Kit is running.")
                    .foregroundStyle(.secondary)
            }
            Section("Login") {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.loginStatus == .enabled || controller.loginStatus == .requiresApproval },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                .disabled(!controller.canRegisterLogin)
                if !controller.canRegisterLogin {
                    Text("Open the packaged Mac Utility Kit app to use this setting.")
                        .foregroundStyle(.secondary)
                }
                if controller.loginStatus == .requiresApproval {
                    Text("Allow Mac Utility Kit in System Settings to finish setup.")
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = controller.loginError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 510)
        .task {
            controller.attach(openWindow: openWindow)
            controller.refreshLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshLoginStatus()
        }
    }
}

struct ToolLauncherView: View {
    let controller: LauncherController
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selection: Tool?

    private var results: [Tool] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let titles = Tool.allCases.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
        guard !search.isEmpty else { return titles }
        return titles + Tool.allCases.filter {
            !$0.title.localizedStandardContains(search) && $0.category.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Find a tool", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let tool = selection ?? results.first { launch(tool) } }
                .onKeyPress(.downArrow) { moveSelection(by: 1) }
                .onKeyPress(.upArrow) { moveSelection(by: -1) }
            if results.isEmpty {
                ContentUnavailableView("No matching tools", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    List(results, id: \.self, selection: $selection) { tool in
                        Button { launch(tool) } label: {
                            HStack {
                                Label(tool.title, systemImage: tool.symbol)
                                Spacer()
                                Text(tool.category).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(tool)
                    }
                    .onChange(of: selection) { _, tool in
                        if let tool { scroll.scrollTo(tool) }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 300, idealHeight: 370)
        .task {
            controller.attach(openWindow: openWindow)
            searchFocused = true
        }
        .onChange(of: query) { selection = nil }
        .onExitCommand { dismissWindow(id: LauncherController.launcherID) }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let matches = results
        guard !matches.isEmpty else { return .ignored }
        if let selection, let index = matches.firstIndex(of: selection) {
            self.selection = matches[min(max(0, index + offset), matches.count - 1)]
        } else {
            selection = offset > 0 ? matches.first : matches.last
        }
        return .handled
    }

    private func launch(_ tool: Tool) {
        dismissWindow(id: LauncherController.launcherID)
        controller.showWorkspace(tool: tool)
    }
}
