import AppKit
import KeyboardShortcuts
import Observation
import ServiceManagement
import SwiftUI
import UtilityCore

extension KeyboardShortcuts.Name {
    static let toolLauncher = Self("toolLauncher")
}

@MainActor
@Observable
final class LauncherController {
    static let workspaceID = "utility-workspace"
    static let launcherID = "utility-launcher"

    var menuBarEnabled: Bool {
        didSet {
            defaults.set(menuBarEnabled, forKey: "launcher.menuBarEnabled")
            if !menuBarEnabled { hideDockIcon = false }
            applyActivationPolicy()
        }
    }

    var hideDockIcon: Bool {
        didSet {
            defaults.set(hideDockIcon, forKey: "launcher.hideDockIcon")
            applyActivationPolicy()
        }
    }

    private(set) var loginStatus: SMAppService.Status = .notFound
    private(set) var loginError: String?
    let canRegisterLogin = Bundle.main.bundleURL.pathExtension.lowercased() == "app"

    private let defaults: UserDefaults
    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var routes: [ObjectIdentifier: WorkspaceRoute] = [:]
    @ObservationIgnored private var pendingTool: Tool?

    private struct WorkspaceRoute {
        weak var window: NSWindow?
        let openTool: @MainActor (Tool) -> Void
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let menuBarVisible = defaults.bool(forKey: "launcher.menuBarEnabled")
        menuBarEnabled = menuBarVisible
        hideDockIcon = menuBarVisible && defaults.bool(forKey: "launcher.hideDockIcon")
    }

    func attach(openWindow: OpenWindowAction) {
        if self.openWindow == nil {
            KeyboardShortcuts.onKeyUp(for: .toolLauncher) { [weak self] in
                Task { @MainActor in self?.showLauncher() }
            }
            applyActivationPolicy()
        }
        self.openWindow = openWindow
    }

    func showLauncher() {
        NSApp.activate()
        openWindow?(id: Self.launcherID)
    }

    func showWorkspace(tool: Tool? = nil) {
        NSApp.activate()
        routes = routes.filter { $0.value.window != nil }
        let visible = NSApp.orderedWindows.first { $0.isVisible && routes[ObjectIdentifier($0)] != nil }
        let minimized = routes.values.compactMap(\.window).first(where: \.isMiniaturized)
        if let window = visible ?? minimized, let route = routes[ObjectIdentifier(window)] {
            if let tool { route.openTool(tool) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        pendingTool = tool
        openWindow?(id: Self.workspaceID)
    }

    func register(_ window: NSWindow, openTool: @escaping @MainActor (Tool) -> Void) {
        routes[ObjectIdentifier(window)] = WorkspaceRoute(window: window, openTool: openTool)
        guard let tool = pendingTool else { return }
        pendingTool = nil
        Task { @MainActor in openTool(tool) }
    }

    func unregister(_ window: NSWindow) {
        routes.removeValue(forKey: ObjectIdentifier(window))
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(menuBarEnabled && hideDockIcon ? .accessory : .regular)
    }

    func refreshLoginStatus() {
        loginStatus = canRegisterLogin ? SMAppService.mainApp.status : .notFound
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard canRegisterLogin else { return }
        loginError = nil
        defer { refreshLoginStatus() }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = error.localizedDescription
        }
    }
}

struct LauncherWorkspaceBridge: NSViewRepresentable {
    let controller: LauncherController
    let openTool: @MainActor (Tool) -> Void
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> WorkspaceWindowObserver {
        WorkspaceWindowObserver()
    }

    func updateNSView(_ view: WorkspaceWindowObserver, context: Context) {
        view.controller = controller
        view.openTool = openTool
        view.connect()
        let action = openWindow
        Task { @MainActor in controller.attach(openWindow: action) }
    }

    final class WorkspaceWindowObserver: NSView {
        weak var controller: LauncherController?
        weak var registeredWindow: NSWindow?
        var openTool: (@MainActor (Tool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        func connect() {
            if let oldWindow = registeredWindow, oldWindow !== window { controller?.unregister(oldWindow) }
            registeredWindow = window
            if let window, let openTool { controller?.register(window, openTool: openTool) }
        }
    }
}
