import Foundation
import Observation

@MainActor
package protocol KeyboardCleaningInput {
    var hasHeldKeys: Bool { get }
    func install(until deadline: ContinuousClock.Instant, interrupted: @escaping @MainActor () -> Void) throws
    func remove()
}

@MainActor
@Observable
package final class KeyboardCleaningSession {
    package private(set) var remainingSeconds = 0
    package private(set) var status: String?
    package var active: Bool { remainingSeconds > 0 }

    private let input: any KeyboardCleaningInput
    @ObservationIgnored private var countdown: Task<Void, Never>?
    @ObservationIgnored private var run: UUID?

    package init(input: any KeyboardCleaningInput) {
        self.input = input
    }

    deinit { countdown?.cancel() }

    package func start(seconds: Int) {
        guard !active else { return }
        if input.hasHeldKeys {
            status = "Release all keys before starting the keyboard pause."
            return
        }
        status = nil
        let seconds = min(120, max(1, seconds))
        let deadline = ContinuousClock.now + .seconds(seconds)
        let id = UUID()
        run = id
        do {
            try input.install(until: deadline) { [weak self] in
                guard let self, self.run == id else { return }
                self.stop(message: "macOS ended the keyboard pause.")
            }
        } catch {
            run = nil
            input.remove()
            status = error.localizedDescription
            return
        }

        guard run == id else { return }
        remainingSeconds = seconds
        countdown = Task { [weak self] in
            for second in stride(from: seconds - 1, through: 0, by: -1) {
                do { try await ContinuousClock().sleep(until: deadline - .seconds(second)) }
                catch { return }
                guard let self, self.run == id, !Task.isCancelled else { return }
                if second == 0 {
                    self.stop(message: "Cleaning time ended. Keyboard input is available.")
                } else {
                    self.remainingSeconds = second
                }
            }
        }
    }

    package func stop(message: String? = nil) {
        guard run != nil else { return }
        run = nil
        countdown?.cancel()
        countdown = nil
        input.remove()
        remainingSeconds = 0
        status = message
    }
}
