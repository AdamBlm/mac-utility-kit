import Foundation
import Testing
@testable import UtilityCore

@MainActor
struct KeyboardCleaningSessionTests {
    private final class Input: KeyboardCleaningInput {
        var denied = false
        var installing = 0
        var removing = 0
        var interrupted: (@MainActor () -> Void)?

        func install(until deadline: ContinuousClock.Instant, interrupted: @escaping @MainActor () -> Void) throws {
            if denied { throw ToolError.invalid("Denied") }
            installing += 1
            self.interrupted = interrupted
        }

        func remove() {
            removing += 1
            interrupted = nil
        }
    }

    @Test func permissionDenialNeverActivates() {
        let input = Input()
        input.denied = true
        let session = KeyboardCleaningSession(input: input)
        session.start(seconds: 60)
        #expect(!session.active)
        #expect(input.installing == 0)
        #expect(input.removing == 1)
        #expect(session.status == "Denied")
    }

    @Test func manualStopAndInterruptionReleaseInputAndIgnoreOldCallbacks() throws {
        let input = Input()
        let session = KeyboardCleaningSession(input: input)
        session.start(seconds: 15)
        session.start(seconds: 60)
        #expect(session.remainingSeconds == 15)
        #expect(input.installing == 1)
        let staleInterrupt = try #require(input.interrupted)
        session.stop()
        session.stop()
        #expect(!session.active)
        #expect(input.removing == 1)

        session.start(seconds: 15)
        staleInterrupt()
        #expect(session.active)
        input.interrupted?()
        #expect(!session.active)
        #expect(input.removing == 2)
    }

    @Test func countdownRestoresInputAutomatically() async throws {
        let input = Input()
        let session = KeyboardCleaningSession(input: input)
        session.start(seconds: 1)
        #expect(session.active)
        let waitUntil = ContinuousClock.now + .seconds(2)
        while session.active && ContinuousClock.now < waitUntil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!session.active)
        #expect(input.removing == 1)
    }
}
