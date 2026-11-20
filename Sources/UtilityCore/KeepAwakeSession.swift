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

    public convenience init(keepDisplayAwake: Bool) throws {
        try self.init(keepDisplayAwake: keepDisplayAwake, timeoutSeconds: 0)
    }

    package init(keepDisplayAwake: Bool, timeoutSeconds: Double) throws {
        do {
            try acquire(kIOPMAssertionTypePreventUserIdleSystemSleep, timeoutSeconds: timeoutSeconds)
            if keepDisplayAwake {
                try acquire(kIOPMAssertionTypePreventUserIdleDisplaySleep, timeoutSeconds: timeoutSeconds)
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

    private func acquire(_ type: String, timeoutSeconds: Double) throws {
        var assertion: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithDescription(
            type as CFString, "Mac Utility Kit Keep Awake" as CFString,
            nil, nil, nil, timeoutSeconds, nil, &assertion
        )
        guard status == kIOReturnSuccess else { throw KeepAwakeError(status: status) }
        assertions.append(assertion)
    }
}

package enum KeepAwakeSchedule {
    package static let supportedMinutes = 1...10_080

    package static func extendedDeadline(
        _ deadline: ContinuousClock.Instant, byMinutes minutes: Int, now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        guard supportedMinutes.contains(minutes), deadline > now else { return nil }
        let extended = deadline.advanced(by: .seconds(minutes * 60))
        let maximum = now.advanced(by: .seconds(supportedMinutes.upperBound * 60))
        return extended <= maximum ? extended : nil
    }
}
