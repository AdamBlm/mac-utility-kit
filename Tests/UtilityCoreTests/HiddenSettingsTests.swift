import CoreFoundation
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

    @Test func filenameExtensionsUseTheGlobalDomainAndSupportReversibleValues() throws {
        let setting = HiddenSetting.macOSFilenameExtensions
        #expect(setting.application == .macOS)
        #expect(CFEqual(setting.application.domain, kCFPreferencesAnyApplication))
        #expect(CFEqual(setting.application.managementDomain, "com.apple.finder" as CFString))
        #expect(setting.key == "AppleShowAllExtensions")

        var stored = HiddenSettingValue.systemDefault
        for next in [HiddenSettingValue.enabled, .disabled, .systemDefault] {
            try HiddenSettings.apply(next, expecting: stored, read: { stored }) { stored = $0 }
            #expect(stored == next)
        }
        stored = .managed
        #expect(throws: ToolError.self) {
            try HiddenSettings.apply(.enabled, expecting: .managed, read: { stored }) { stored = $0 }
        }
        #expect(stored == .managed)
    }

    @Test func recognizesCurrentHostOverrideAndRefusesToWriteAroundIt() {
        let enabled = NSNumber(value: true)
        let disabled = NSNumber(value: false)
        #expect(HiddenSettings.storedValue(currentHost: nil, anyHost: enabled) == .enabled)
        #expect(HiddenSettings.storedValue(currentHost: disabled, anyHost: enabled) == .hostOverride)
        #expect(HiddenSettings.storedValue(currentHost: "Unrecognized" as NSString, anyHost: nil) == .hostOverride)
        #expect(throws: ToolError.self) {
            try HiddenSettings.apply(.enabled, expecting: .systemDefault, read: { .hostOverride }) { _ in
                Issue.record("A host override must prevent the any-host write.")
            }
        }
        #expect(!HiddenSettingValue.hostOverride.canChange)
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
