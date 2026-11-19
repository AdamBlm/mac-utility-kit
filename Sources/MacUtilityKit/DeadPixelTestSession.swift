import AppKit
import CoreGraphics
import Observation
import UtilityCore

@MainActor
@Observable
final class DeadPixelTestSession {
    private static weak var running: DeadPixelTestSession?

    struct Display: Identifiable, Sendable {
        let id: UInt32
        let name: String
        let status: DeadPixelTargetStatus

        init?(_ screen: NSScreen) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            id = number.uint32Value
            name = screen.localizedName
            status = DeadPixelTargetStatus(connected: true, mirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
    }

    private(set) var displays: [Display] = []
    private(set) var active = false
    private(set) var issue: String?
    @ObservationIgnored private var sequence = DeadPixelSequence()
    @ObservationIgnored private var window: PixelTestWindow?
    @ObservationIgnored private var canvas: PixelTestCanvas?
    @ObservationIgnored private weak var formerWindow: NSWindow?
    @ObservationIgnored private var displayID: UInt32?
    @ObservationIgnored private var cycle: Task<Void, Never>?
    @ObservationIgnored private var cycling = false
    @ObservationIgnored private var automatic = false
    @ObservationIgnored private var interval = 3

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap(Display.init)
        guard active, let displayID else { return }
        let screen = screen(for: displayID)
        switch targetStatus(displayID, connected: screen != nil) {
        case .available:
            if let screen {
                window?.setFrame(screen.frame, display: true)
                window?.colorSpace = screen.colorSpace
            }
        case .disconnected:
            finish(message: "The selected display disconnected. The test ended.")
        case .mirrored:
            finish(message: "Display mirroring was enabled. The test ended.")
        }
    }

    func start(displayID: UInt32, automatically: Bool, interval: Int, startingColor: DeadPixelColor = .black) {
        guard !active else { return }
        guard Self.running == nil else {
            issue = "End the current display test before starting another."
            return
        }
        guard let screen = screen(for: displayID) else {
            issue = "Choose a connected display."
            refreshDisplays()
            return
        }
        guard targetStatus(displayID, connected: true) == .available else {
            issue = "Turn off display mirroring to test this display on its own."
            refreshDisplays()
            return
        }
        issue = nil
        sequence = DeadPixelSequence(startingAt: startingColor)
        formerWindow = NSApp.keyWindow
        self.displayID = displayID
        automatic = automatically
        cycling = automatically
        self.interval = min(10, max(1, interval))

        let panel = PixelTestWindow(contentRect: screen.frame, styleMask: [.borderless],
                                    backing: .buffered, defer: false, screen: screen)
        panel.setFrame(screen.frame, display: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.hasShadow = false
        panel.isOpaque = true
        panel.colorSpace = screen.colorSpace
        panel.backgroundColor = .black
        let surface = PixelTestCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
        surface.color = color(sequence.color)
        surface.perform = { [weak self] action in self?.handle(action) }
        panel.contentView = surface
        panel.makeFirstResponder(surface)
        window = panel
        canvas = surface
        active = true
        Self.running = self
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        schedule()
    }

    func finish(message: String? = nil) {
        guard active else { return }
        cycle?.cancel()
        cycle = nil
        cycling = false
        active = false
        if Self.running === self { Self.running = nil }
        displayID = nil
        if let window {
            window.orderOut(nil)
            window.close()
        }
        canvas = nil
        window = nil
        if NSApp.isActive, formerWindow?.isVisible == true { formerWindow?.makeKey() }
        formerWindow = nil
        issue = message
    }

    private func screen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { Display($0)?.id == id }
    }

    private func schedule() {
        cycle?.cancel()
        cycle = nil
        guard active, cycling else { return }
        let delay = interval
        cycle = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard let self, self.active, self.cycling else { return }
                self.advance(1)
            }
        }
    }

    private func handle(_ action: PixelTestCanvas.Action) {
        switch action {
        case .quit: finish()
        case .step(let direction):
            advance(direction)
            schedule()
        case .select(let number):
            if sequence.select(number: number) {
                canvas?.color = color(sequence.color)
                if cycling { schedule() }
            }
        case .toggle:
            if automatic {
                cycling.toggle()
                schedule()
            } else {
                advance(1)
            }
        }
    }

    private func advance(_ direction: Int) {
        sequence.step(direction)
        canvas?.color = color(sequence.color)
    }

    private func targetStatus(_ displayID: UInt32, connected: Bool) -> DeadPixelTargetStatus {
        DeadPixelTargetStatus(connected: connected, mirrored: connected && CGDisplayIsInMirrorSet(displayID) != 0)
    }

    private func color(_ shade: DeadPixelColor) -> NSColor {
        switch shade {
        case .black: NSColor(deviceWhite: 0, alpha: 1)
        case .white: NSColor(deviceWhite: 1, alpha: 1)
        case .red: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        case .green: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
        case .blue: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        }
    }
}

private final class PixelTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PixelTestCanvas: NSView {
    enum Action { case quit, step(Int), select(Int), toggle }

    var perform: ((Action) -> Void)?
    var color = NSColor.black { didSet { needsDisplay = true } }
    private let transparentCursor = NSCursor(
        image: NSImage(size: NSSize(width: 16, height: 16), flipped: false, drawingHandler: { _ in true }),
        hotSpot: .zero
    )

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        // The cursor is invisible only over the test window.
        addCursorRect(bounds, cursor: transparentCursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: perform?(.quit)
        case 123: perform?(.step(-1))
        case 124: perform?(.step(1))
        case 49: perform?(.toggle)
        default:
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let key = event.characters, let number = Int(key), (1...DeadPixelColor.allCases.count).contains(number) {
                perform?(.select(number))
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) { perform?(.step(1)) }
    override func rightMouseDown(with event: NSEvent) { perform?(.step(-1)) }
}
