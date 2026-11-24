import AppKit
import UtilityCore

@MainActor
final class ScreenRegionSelector {
    struct Display: Sendable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    struct Selection {
        let region: CGRect
        let displays: [Display]
    }

    private var panels: [RegionPanel] = []
    private var views: [RegionOverlay] = []
    private var displayList: [Display] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var selectionID: UUID?
    private var dragStart: CGPoint?
    private var region: CGRect?
    private var observers: [NSObjectProtocol] = []

    func select() async -> Selection? {
        guard continuation == nil else { return nil }
        let id = UUID()
        let selection: Selection? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                self.selectionID = id
                self.continuation = continuation
                present()
            }
        } onCancel: {
            Task { @MainActor in
                if self.selectionID == id { self.cancel() }
            }
        }
        return Task.isCancelled ? nil : selection
    }

    func cancel() { finish(with: nil) }

    private func present() {
        let screensByID: [(Display, NSScreen)] = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (Display(id: id.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor), screen)
        }
        guard !screensByID.isEmpty else { cancel(); return }
        displayList = screensByID.map(\.0)
        let center = NotificationCenter.default
        guard let id = selectionID else { return }
        for signal in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: signal, object: NSApp, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.selectionID == id else { return }
                    self.cancel()
                }
            })
        }
        let mouse = NSEvent.mouseLocation
        var preferred: RegionPanel?
        for (display, screen) in screensByID {
            let panel = RegionPanel(contentRect: display.frame, styleMask: [.borderless],
                                    backing: .buffered, defer: false, screen: screen)
            panel.setFrame(display.frame, display: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovable = false
            let overlay = RegionOverlay(frame: CGRect(origin: .zero, size: display.frame.size), selector: self)
            panel.contentView = overlay
            panel.makeFirstResponder(overlay)
            panels.append(panel)
            views.append(overlay)
            panel.orderFrontRegardless()
            if display.frame.contains(mouse) { preferred = panel }
        }
        NSApp.activate()
        (preferred ?? panels.first)?.makeKey()
    }

    fileprivate func start(at point: CGPoint) {
        dragStart = point
        update(at: point)
    }

    fileprivate func update(at point: CGPoint) {
        guard let start = dragStart else { return }
        show(CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                    width: abs(start.x - point.x), height: abs(start.y - point.y)))
    }

    fileprivate func end(at point: CGPoint) {
        update(at: point)
        dragStart = nil
    }

    fileprivate func adjust(by delta: CGVector, resizing: Bool) {
        guard dragStart == nil, let region, region.width >= 2, region.height >= 2 else { return }
        show(CaptureRegionGeometry.adjusting(region, by: delta, resizing: resizing,
                                             displays: displayList.map(\.frame)))
    }

    private func show(_ region: CGRect) {
        self.region = region
        for view in views { view.selection = region }
    }

    fileprivate func confirm() {
        guard let region, region.width >= 2, region.height >= 2 else {
            NSSound.beep()
            return
        }
        finish(with: Selection(region: region, displays: displayList))
    }

    private func finish(with result: Selection?) {
        guard let continuation else { return }
        self.continuation = nil
        selectionID = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        displayList.removeAll()
        dragStart = nil
        region = nil
        continuation.resume(returning: result)
    }
}

private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionOverlay: NSView {
    private weak var selector: ScreenRegionSelector?
    var selection: CGRect? { didSet { needsDisplay = true } }

    init(frame: CGRect, selector: ScreenRegionSelector) {
        self.selector = selector
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let point = screenPoint(event) { selector?.start(at: point) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let point = screenPoint(event) { selector?.update(at: point) }
    }

    override func mouseUp(with event: NSEvent) {
        if let point = screenPoint(event) { selector?.end(at: point) }
    }

    override func keyDown(with event: NSEvent) {
        let resizing = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: selector?.cancel()
        case 36, 76: selector?.confirm()
        case 123: selector?.adjust(by: CGVector(dx: -1, dy: 0), resizing: resizing)
        case 124: selector?.adjust(by: CGVector(dx: 1, dy: 0), resizing: resizing)
        case 125: selector?.adjust(by: CGVector(dx: 0, dy: -1), resizing: resizing)
        case 126: selector?.adjust(by: CGVector(dx: 0, dy: 1), resizing: resizing)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.39).setFill()
        bounds.fill(using: .copy)
        if let selection, let window {
            let local = convert(window.convertFromScreen(selection), from: nil)
            NSColor.white.withAlphaComponent(0.045).setFill()
            local.fill(using: .copy)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let outline = NSBezierPath(rect: local.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1.5
            outline.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let instruction = NSAttributedString(
            string: "Drag to select  •  Arrows move  •  Shift-arrows resize  •  Return captures  •  Esc cancels",
            attributes: attributes
        )
        let size = instruction.size()
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 29)
        let backdrop = NSBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -12, dy: -7),
                                    xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.8).setFill()
        backdrop.fill()
        instruction.draw(at: origin)
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint? {
        window?.convertPoint(toScreen: event.locationInWindow)
    }
}
