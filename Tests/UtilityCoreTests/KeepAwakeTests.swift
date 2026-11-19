import Testing
import UtilityCore

@Test func keepAwakeExtensionUsesTheRemainingDeadlineAndRejectsExpiredOrExcessiveSessions() {
    let now = ContinuousClock.now
    let deadline = now.advanced(by: .seconds(2 * 60))
    let extended = KeepAwakeSchedule.extendedDeadline(deadline, byMinutes: 15, now: now)
    #expect(extended == now.advanced(by: .seconds(17 * 60)))
    #expect(KeepAwakeSchedule.extendedDeadline(now, byMinutes: 15, now: now) == nil)
    #expect(KeepAwakeSchedule.extendedDeadline(deadline, byMinutes: 0, now: now) == nil)
    let maximum = KeepAwakeSchedule.supportedMinutes.upperBound
    let justWithin = now.advanced(by: .seconds((maximum - 15) * 60))
    #expect(KeepAwakeSchedule.extendedDeadline(justWithin, byMinutes: 15, now: now)
            == now.advanced(by: .seconds(maximum * 60)))
    #expect(KeepAwakeSchedule.extendedDeadline(justWithin.advanced(by: .seconds(1)), byMinutes: 15, now: now) == nil)
}
