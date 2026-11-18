import AppKit
import Observation
import UtilityCore

@MainActor
@Observable
final class PresentationModeController: NSObject {
    private(set) var isActive = false
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var issue: String?
    private(set) var needsRecovery = false
    private(set) var hidesDesktop = false
    private(set) var hidesDock = false
    private(set) var keepsAwake = false
    @ObservationIgnored private var dock: PresentationDockSession?
    @ObservationIgnored private var awake: KeepAwakeSession?
    @ObservationIgnored private var desktop: PresentationDesktopCover?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var status: NSStatusItem?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
                                              name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                              name: NSApplication.didChangeScreenParametersNotification, object: nil)
        recover()
    }

    func start(hideDesktop: Bool, hideDock: Bool, keepAwake: Bool, minutes: Int?) {
        guard !isActive, hideDesktop || hideDock || keepAwake else { return }
        guard minutes.map(KeepAwakeController.supportedMinutes.contains) != false else {
            issue = KeepAwakeController.invalidDurationMessage
            return
        }
        guard !hideDock || !needsRecovery else {
            issue = "Resolve the previous Dock restoration before starting another Dock session."
            return
        }
        issue = nil
        do {
            if hideDock { dock = try PresentationDockSession.start() }
            if keepAwake { awake = try KeepAwakeSession(keepDisplayAwake: true) }
            if hideDesktop {
                let cover = PresentationDesktopCover()
                cover.update()
                desktop = cover
            }
            hidesDesktop = hideDesktop
            hidesDock = hideDock
            keepsAwake = keepAwake
            isActive = true
            installStatus()
            beginTasks(minutes: minutes)
        } catch {
            let startError = error.localizedDescription
            stop()
            issue = [startError, issue].compactMap { $0 }.joined(separator: " ")
            if hideDock { needsRecovery = PresentationDockSession.hasRecovery }
        }
    }

    @objc func stop() {
        timer?.cancel()
        observer?.cancel()
        timer = nil
        observer = nil
        if let status { NSStatusBar.system.removeStatusItem(status) }
        status = nil
        awake?.stop()
        awake = nil
        desktop?.stop()
        desktop = nil
        if let dock {
            do {
                show(try dock.stop(), recovering: false)
            } catch {
                issue = "Could not restore Dock visibility. \(error.localizedDescription)"
                needsRecovery = true
            }
        }
        dock = nil
        isActive = false
        deadline = nil
        hidesDesktop = false
        hidesDock = false
        keepsAwake = false
    }

    func recover() {
        guard !isActive else { return }
        do {
            let outcome = try PresentationDockSession.recoverInterruptedSession()
            needsRecovery = false
            show(outcome, recovering: true)
        } catch {
            needsRecovery = true
            issue = "Could not recover Dock visibility. \(error.localizedDescription)"
        }
    }

    private func beginTasks(minutes: Int?) {
        if let minutes {
            let end = ContinuousClock.now + .seconds(minutes * 60)
            deadline = end
            timer = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: end) } catch { return }
                if !Task.isCancelled { self?.stop() }
            }
        }
        if dock != nil {
            observer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, let dock = self.dock else { return }
                    do {
                        if try dock.relinquishIfChanged() {
                            self.dock = nil
                            self.hidesDock = false
                            self.issue = "Dock visibility changed outside Presentation Mode. The current setting will be kept."
                            return
                        }
                    } catch {
                        self.issue = "Could not verify the Dock setting. \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func show(_ outcome: PresentationDockSession.Restoration, recovering: Bool) {
        switch outcome {
        case .restored:
            issue = recovering ? "Restored the Dock setting from the interrupted session." : nil
        case .changedElsewhere:
            issue = "The Dock setting changed outside Presentation Mode. The current setting was kept."
        case .uncertain:
            issue = "An interrupted Dock change could not be attributed. The current setting was kept."
        case .unchanged:
            if recovering { issue = nil }
        }
    }

    private func installStatus() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Presentation"
        let menu = NSMenu()
        let stop = NSMenuItem(title: "Stop Presentation Mode", action: #selector(stop), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        item.menu = menu
        status = item
    }

    @objc private func applicationWillTerminate() { if isActive { stop() } }
    @objc private func displaysChanged() { desktop?.update() }
}
