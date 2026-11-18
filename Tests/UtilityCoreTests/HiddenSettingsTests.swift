import Foundation
import Testing
@testable import UtilityCore

struct HiddenSettingsTests {
    @Test func appliesAndResetsOneTypedPreference() throws {
        var stored = HiddenSettingValue.systemDefault
        try HiddenSettings.apply(.enabled, expecting: .systemDefault, read: { stored }) { stored = $0 }
        #expect(stored == .enabled)
        try HiddenSettings.apply(.systemDefault, expecting: .enabled, read: { stored }) { stored = $0 }
        #expect(stored == .systemDefault)
    }

    @Test func refusesChangedManagedAndUnexpectedValues() {
        #expect(throws: ToolError.self) {
            try HiddenSettings.apply(.enabled, expecting: .disabled, read: { .managed }) { _ in
                Issue.record("An externally changed preference reached the setter.")
            }
        }
        #expect(throws: ToolError.self) {
            try HiddenSettings.apply(.enabled, expecting: .disabled, read: { .disabled }) { _ in }
        }
        #expect(HiddenSettings.interpreted(NSNumber(value: true)) == .enabled)
        #expect(HiddenSettings.interpreted("YES" as NSString) == .enabled)
        #expect(HiddenSettings.interpreted(NSNumber(value: 12)) == .unavailable)
    }
}
