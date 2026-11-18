import AppKit
import ApplicationServices
import UtilityCore

@MainActor
final class CleanKeyboardInput: KeyboardCleaningInput {
    private var resources: EventTapResources?
    private var deadline: ContinuousClock.Instant?
    private var interrupted: (@MainActor () -> Void)?

    var hasPermission: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func install(until deadline: ContinuousClock.Instant, interrupted: @escaping @MainActor () -> Void) throws {
        guard NSApp.isActive,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true
        else { throw ToolError.invalid("Start cleaning from an active, signed-in Mac session.") }

        guard hasPermission else {
            throw ToolError.invalid("Allow Mac Utility Kit in Accessibility settings first.")
        }

        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw ToolError.invalid("macOS did not allow the keyboard pause. Check Accessibility and Input Monitoring settings.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw ToolError.invalid("Could not start the keyboard pause.")
        }

        self.deadline = deadline
        self.interrupted = interrupted
        resources = EventTapResources(tap: tap, source: source)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            remove()
            throw ToolError.invalid("macOS disabled the keyboard pause.")
        }
    }

    func remove() {
        resources = nil
        deadline = nil
        interrupted = nil
    }

    // The callback runs on the main run loop. It never reads or retains a key value.
    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let input = Unmanaged<CleanKeyboardInput>.fromOpaque(context).takeUnretainedValue()
        let suppress = MainActor.assumeIsolated { input.shouldSuppress(type) }
        return suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func shouldSuppress(_ type: CGEventType) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let interrupted { Task { @MainActor in interrupted() } }
            return false
        }
        return deadline.map { ContinuousClock.now < $0 } ?? false
    }

    private final class EventTapResources {
        let tap: CFMachPort
        let source: CFRunLoopSource

        init(tap: CFMachPort, source: CFRunLoopSource) {
            self.tap = tap
            self.source = source
        }

        deinit {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
        }
    }
}
