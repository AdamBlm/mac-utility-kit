import AppKit

@MainActor
final class ScreenRecordingStatusItem: NSObject {
    private var item: NSStatusItem?
    private var currentActionTitle: String?
    private var action: (() -> Void)?
    private var stop: (() -> Void)?

    func update(_ title: String, actionTitle: String?, action: (() -> Void)?, onStop: @escaping () -> Void) {
        let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        self.action = action
        stop = onStop
        item.button?.title = title
        item.button?.toolTip = "Mac Utility Kit screen recording"
        guard item.menu == nil || currentActionTitle != actionTitle else { return }
        currentActionTitle = actionTitle
        let menu = NSMenu()
        if let actionTitle {
            let item = NSMenuItem(title: actionTitle, action: #selector(runAction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let stopItem = NSMenuItem(title: "Stop Screen Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)
        item.menu = menu
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        currentActionTitle = nil
        action = nil
        stop = nil
    }

    @objc private func runAction() { action?() }
    @objc private func stopRecording() { stop?() }
}
