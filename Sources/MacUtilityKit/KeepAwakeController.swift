import Foundation
import Observation
import UtilityCore

@MainActor
@Observable
final class KeepAwakeController {
    static let supportedMinutes = KeepAwakeSchedule.supportedMinutes
    static let invalidDurationMessage = "Enter a whole number from 1 to 10,080 minutes."

    private(set) var isActive = false
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var error: String?
    private(set) var keepsDisplayAwake = false
    @ObservationIgnored private var session: KeepAwakeSession?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    func start(minutes: Int?, keepDisplayAwake: Bool) {
        guard session == nil else { return }
        error = nil
        if let minutes, !Self.supportedMinutes.contains(minutes) {
            error = Self.invalidDurationMessage
            return
        }
        do {
            let seconds = minutes.map { $0 * 60 }
            let end = seconds.map { ContinuousClock.now.advanced(by: .seconds($0)) }
            session = try KeepAwakeSession(keepDisplayAwake: keepDisplayAwake, timeoutSeconds: Double(seconds ?? 0))
            isActive = true
            keepsDisplayAwake = keepDisplayAwake
            if let end { scheduleExpiry(end) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func extend(minutes: Int) {
        guard let session, let deadline else { return }
        let now = ContinuousClock.now
        guard deadline > now else { stop(); return }
        guard let extended = KeepAwakeSchedule.extendedDeadline(deadline, byMinutes: minutes, now: now) else {
            error = "A session can have up to seven days remaining."
            return
        }
        let remaining = now.duration(to: extended).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        do {
            // Acquire both replacements before releasing the current coverage.
            let replacement = try KeepAwakeSession(keepDisplayAwake: keepsDisplayAwake, timeoutSeconds: seconds)
            self.session = replacement
            session.stop()
            error = nil
            scheduleExpiry(extended)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func scheduleExpiry(_ end: ContinuousClock.Instant) {
        expiry?.cancel()
        deadline = end
        expiry = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: end) }
            catch { return }
            guard !Task.isCancelled, let self, self.deadline == end else { return }
            self.stop()
        }
    }

    func stop() {
        expiry?.cancel()
        expiry = nil
        session?.stop()
        session = nil
        deadline = nil
        error = nil
        isActive = false
        keepsDisplayAwake = false
    }
}
