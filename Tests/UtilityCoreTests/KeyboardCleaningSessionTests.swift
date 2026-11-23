import Foundation
import Testing
@testable import UtilityCore

@MainActor
struct KeyboardCleaningSessionTests {
    private final class Input: KeyboardCleaningInput {
        var denied = false
        var hasHeldKeys = false
        var installing = 0
        var removing = 0
        var interrupted: (@MainActor () -> Void)?
        var deadline: ContinuousClock.Instant?
        var onRemove: (() -> Void)?

        func install(until deadline: ContinuousClock.Instant, interrupted: @escaping @MainActor () -> Void) throws {
            if denied { throw ToolError.invalid("Denied") }
            installing += 1
            self.deadline = deadline
            self.interrupted = interrupted
        }

        func remove() {
            removing += 1
            interrupted = nil
            onRemove?()
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

    @Test func heldKeysPreventActivationUntilReleased() {
        let input = Input()
        let session = KeyboardCleaningSession(input: input)
        input.hasHeldKeys = true
        session.start(seconds: 30)
        #expect(!session.active)
        #expect(input.installing == 0)
        #expect(session.status == "Release all keys before starting the keyboard pause.")

        input.hasHeldKeys = false
        session.start(seconds: 30)
        #expect(session.active)
        #expect(input.installing == 1)
        #expect(session.status == nil)
        session.stop()
        #expect(input.removing == 1)
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

    @Test func deallocationRemovesInstalledInputEvenWhenItHasAnotherOwner() {
        let input = Input()
        var session: KeyboardCleaningSession? = KeyboardCleaningSession(input: input)
        session?.start(seconds: 60)
        #expect(session?.active == true)
        #expect(input.installing == 1)
        session = nil
        #expect(input.removing == 1)
        #expect(input.interrupted == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func countdownRestoresInputAutomatically() async throws {
        let input = Input()
        let (removals, continuation) = AsyncStream<ContinuousClock.Instant>.makeStream()
        defer { continuation.finish() }
        input.onRemove = { continuation.yield(ContinuousClock.now) }

        let session = KeyboardCleaningSession(input: input)
        session.start(seconds: 1)
        #expect(session.active)
        let deadline = try #require(input.deadline)
        var events = removals.makeAsyncIterator()
        let removedAt = try #require(await events.next())
        #expect(removedAt >= deadline)
        #expect(!session.active)
        #expect(input.removing == 1)
    }
}
