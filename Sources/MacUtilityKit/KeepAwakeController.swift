import Foundation
import Observation
import UtilityCore

@MainActor
@Observable
final class KeepAwakeController {
    static let supportedMinutes = 1...10_080
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
            session = try KeepAwakeSession(keepDisplayAwake: keepDisplayAwake)
            isActive = true
            keepsDisplayAwake = keepDisplayAwake
            if let minutes {
                let end = ContinuousClock.now.advanced(by: .seconds(minutes * 60))
                deadline = end
                expiry = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: end) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    self?.stop()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        expiry?.cancel()
        expiry = nil
        session?.stop()
        session = nil
        deadline = nil
        isActive = false
        keepsDisplayAwake = false
    }
}
