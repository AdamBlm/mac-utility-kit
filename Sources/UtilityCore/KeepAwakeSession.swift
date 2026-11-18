import Foundation
import IOKit.pwr_mgt

public struct KeepAwakeError: LocalizedError {
    public let status: IOReturn

    public var errorDescription: String? {
        "macOS could not create the sleep prevention assertion (status \(status))."
    }
}

/// Process-owned idle sleep assertions are also cleared by macOS on process exit.
public final class KeepAwakeSession {
    private var assertions: [IOPMAssertionID] = []

    public init(keepDisplayAwake: Bool) throws {
        do {
            try acquire(kIOPMAssertionTypePreventUserIdleSystemSleep)
            if keepDisplayAwake {
                try acquire(kIOPMAssertionTypePreventUserIdleDisplaySleep)
            }
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    public func stop() {
        for assertion in assertions { IOPMAssertionRelease(assertion) }
        assertions.removeAll()
    }

    private func acquire(_ type: String) throws {
        var assertion: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Mac Utility Kit Keep Awake" as CFString, &assertion
        )
        guard status == kIOReturnSuccess else { throw KeepAwakeError(status: status) }
        assertions.append(assertion)
    }
}
