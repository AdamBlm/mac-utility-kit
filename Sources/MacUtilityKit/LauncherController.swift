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
    @ObservationIgnored private var pendingPDFs: [URL] = []

    private struct WorkspaceRoute {
        weak var window: NSWindow?
        let openTool: @MainActor (Tool) -> Void
        let openPDFs: @MainActor ([URL]) -> Void
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
        if let route = revealWorkspace() {
            if let tool { route.openTool(tool) }
        } else {
            pendingTool = tool
            openWindow?(id: Self.workspaceID)
        }
    }

    func openPDFs(_ urls: [URL], opensWorkspaceIfNeeded: Bool = true) {
        if let route = revealWorkspace() {
            route.openPDFs(urls)
        } else {
            let alreadyWaiting = !pendingPDFs.isEmpty
            pendingPDFs.append(contentsOf: urls)
            if opensWorkspaceIfNeeded && !alreadyWaiting {
                openWindow?(id: Self.workspaceID)
            }
        }
    }

    private func revealWorkspace() -> WorkspaceRoute? {
        // Activation alone can leave windows hidden. Restore their visibility before routing.
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate()
        routes = routes.filter { $0.value.window != nil }
        let visible = NSApp.orderedWindows.first { $0.isVisible && routes[ObjectIdentifier($0)] != nil }
        let minimized = NSApp.windows.first { $0.isMiniaturized && routes[ObjectIdentifier($0)] != nil }
        guard let window = visible ?? minimized, let route = routes[ObjectIdentifier(window)] else { return nil }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return route
    }

    func register(_ window: NSWindow, openTool: @escaping @MainActor (Tool) -> Void,
                  openPDFs: @escaping @MainActor ([URL]) -> Void) {
        routes[ObjectIdentifier(window)] = WorkspaceRoute(window: window, openTool: openTool, openPDFs: openPDFs)
        let tool = pendingTool
        let pdfs = pendingPDFs
        pendingTool = nil
        pendingPDFs.removeAll()
        guard tool != nil || !pdfs.isEmpty else { return }
        Task { @MainActor in
            if let tool { openTool(tool) }
            if !pdfs.isEmpty { openPDFs(pdfs) }
        }
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
    let openPDFs: @MainActor ([URL]) -> Void
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> WorkspaceWindowObserver {
        WorkspaceWindowObserver()
    }

    func updateNSView(_ view: WorkspaceWindowObserver, context: Context) {
        view.controller = controller
        view.openTool = openTool
        view.openPDFs = openPDFs
        view.connect()
        let action = openWindow
        Task { @MainActor in controller.attach(openWindow: action) }
    }

    final class WorkspaceWindowObserver: NSView {
        weak var controller: LauncherController?
        weak var registeredWindow: NSWindow?
        var openTool: (@MainActor (Tool) -> Void)?
        var openPDFs: (@MainActor ([URL]) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        func connect() {
            if let oldWindow = registeredWindow, oldWindow !== window { controller?.unregister(oldWindow) }
            registeredWindow = window
            if let window, let openTool, let openPDFs {
                controller?.register(window, openTool: openTool, openPDFs: openPDFs)
            }
        }
    }
}
