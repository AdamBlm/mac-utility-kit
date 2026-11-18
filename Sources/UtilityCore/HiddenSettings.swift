import CoreFoundation
import Foundation

public enum HiddenSetting: String, CaseIterable, Identifiable, Sendable {
    case finderHiddenFiles
    case finderPathBar
    case finderStatusBar
    case dockAutohide
    case dockRecentApps

    public enum Application: String, CaseIterable, Identifiable, Sendable {
        case finder = "Finder"
        case dock = "Dock"

        public var id: Self { self }
        fileprivate var domain: String { self == .finder ? "com.apple.finder" : "com.apple.dock" }
    }

    public var id: Self { self }

    public var application: Application {
        switch self {
        case .finderHiddenFiles, .finderPathBar, .finderStatusBar: .finder
        case .dockAutohide, .dockRecentApps: .dock
        }
    }

    public var title: String {
        switch self {
        case .finderHiddenFiles: "Show hidden files"
        case .finderPathBar: "Show path bar"
        case .finderStatusBar: "Show status bar"
        case .dockAutohide: "Automatically hide the Dock"
        case .dockRecentApps: "Show recent apps in the Dock"
        }
    }

    public var effect: String {
        switch self {
        case .finderHiddenFiles: "Show entries that Finder normally hides, such as files whose names begin with a dot."
        case .finderPathBar: "Show the folder path below Finder windows."
        case .finderStatusBar: "Show selection and item counts below Finder windows."
        case .dockAutohide: "Show the Dock when you move the pointer to its edge."
        case .dockRecentApps: "Show recently used apps alongside pinned apps."
        }
    }

    fileprivate var key: String {
        switch self {
        case .finderHiddenFiles: "AppleShowAllFiles"
        case .finderPathBar: "ShowPathbar"
        case .finderStatusBar: "ShowStatusBar"
        case .dockAutohide: "autohide"
        case .dockRecentApps: "show-recents"
        }
    }
}

public enum HiddenSettingValue: String, CaseIterable, Identifiable, Sendable {
    case systemDefault = "System Default"
    case enabled = "Enabled"
    case disabled = "Disabled"
    case unavailable = "Unavailable"
    case managed = "Managed by macOS"

    public var id: Self { self }
    public var canChange: Bool { self != .managed && self != .unavailable }
}

public enum HiddenSettings {
    public static func read(_ setting: HiddenSetting) -> HiddenSettingValue {
        let domain = setting.application.domain as CFString
        let key = setting.key as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return .unavailable }
        guard !CFPreferencesAppValueIsForced(key, domain) else { return .managed }
        guard let stored = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return .systemDefault
        }
        return interpreted(stored)
    }

    public static func apply(_ next: HiddenSettingValue, to setting: HiddenSetting, expecting prior: HiddenSettingValue) throws {
        try apply(next, expecting: prior, read: { read(setting) }) { value in
            let key = setting.key as CFString
            let domain = setting.application.domain as CFString
            let stored: CFPropertyList? = switch value {
            case .enabled: kCFBooleanTrue
            case .disabled: kCFBooleanFalse
            default: nil
            }
            CFPreferencesSetValue(key, stored, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                throw ToolError.invalid("macOS could not synchronize this setting.")
            }
        }
    }

    static func apply(
        _ next: HiddenSettingValue, expecting prior: HiddenSettingValue,
        read: () -> HiddenSettingValue, write: (HiddenSettingValue) throws -> Void
    ) throws {
        guard next.canChange, prior.canChange else { throw ToolError.invalid("This setting cannot be edited.") }
        guard read() == prior else { throw ToolError.invalid("The setting changed. Refresh and review it before applying.") }
        guard next != prior else { return }
        try write(next)
        guard read() == next else { throw ToolError.invalid("macOS did not report the requested value after saving.") }
    }

    static func interpreted(_ stored: CFPropertyList) -> HiddenSettingValue {
        if CFGetTypeID(stored) == CFBooleanGetTypeID(), let boolean = stored as? Bool {
            return boolean ? .enabled : .disabled
        }
        // Finder accepts this key from older defaults recipes as a string.
        if let string = stored as? String {
            switch string.lowercased() {
            case "yes", "true", "1": return .enabled
            case "no", "false", "0": return .disabled
            default: break
            }
        }
        return .unavailable
    }
}
