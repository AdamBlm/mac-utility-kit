import AppKit

@MainActor
final class PresentationDesktopCover {
    private var windows: [UInt32: NSWindow] = [:]

    func update() {
        let screens = NSScreen.screens.compactMap { screen -> (UInt32, NSScreen)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (id.uint32Value, screen)
        }
        let currentIDs = Set(screens.map(\.0))
        for id in windows.keys.filter({ !currentIDs.contains($0) }) {
            windows.removeValue(forKey: id)?.close()
        }
        for (id, screen) in screens {
            if let window = windows[id] {
                window.setFrame(screen.frame, display: true)
                continue
            }
            let window = DesktopCoverWindow(contentRect: screen.frame, styleMask: [.borderless],
                                            backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.isMovable = false
            window.hasShadow = false
            window.isOpaque = true
            window.backgroundColor = NSColor(srgbRed: 0.09, green: 0.11, blue: 0.15, alpha: 1)
            window.orderFrontRegardless()
            windows[id] = window
        }
    }

    func stop() {
        windows.values.forEach { $0.close() }
        windows = [:]
    }
}

private final class DesktopCoverWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
