import AppKit
import Darwin
import Foundation

public enum PresentationDockValue: String, Codable, Sendable {
    case missing, shown, autoHidden
}

@MainActor
protocol PresentationDockPreferences: AnyObject {
    func read() throws -> PresentationDockValue
    func write(_ value: PresentationDockValue) throws
    func reload() throws
}

@MainActor
public final class PresentationDockSession {
    public enum Restoration: Equatable, Sendable {
        case unchanged, restored, changedElsewhere, uncertain
    }

    private struct Journal: Codable {
        enum Phase: String, Codable { case preparing, applied, restoring }
        var phase: Phase
        let original: PresentationDockValue
    }

    private let folder: URL
    private let preferences: any PresentationDockPreferences
    private var lease: PresentationSettingsLock?
    private var journal: Journal?
    private var didWrite = false

    public static func start() throws -> PresentationDockSession {
        try start(in: recoveryFolder(), preferences: SystemPresentationDockPreferences())
    }

    public static var hasRecovery: Bool {
        guard let folder = try? recoveryFolder() else { return false }
        return FileManager.default.fileExists(atPath: folder.appending(path: "dock-recovery.json").path)
    }

    public static func recoverInterruptedSession() throws -> Restoration {
        try recover(in: recoveryFolder(), preferences: SystemPresentationDockPreferences())
    }

    static func start(in folder: URL, preferences: any PresentationDockPreferences) throws -> PresentationDockSession {
        let session = PresentationDockSession(folder: folder, preferences: preferences)
        try session.acquire()
        if FileManager.default.fileExists(atPath: session.journalURL.path) {
            throw ToolError.invalid("Restore the previous Dock settings before starting another session.")
        }
        let original = try preferences.read()
        guard original != .autoHidden else {
            session.lease = nil
            return session
        }

        try session.save(Journal(phase: .preparing, original: original))
        do {
            guard try preferences.read() == original else {
                try session.clearJournal()
                throw ToolError.invalid("Dock visibility changed before Presentation Mode could start.")
            }
            try preferences.write(.autoHidden)
            session.didWrite = true
            guard try preferences.read() == .autoHidden else {
                throw ToolError.invalid("macOS did not apply Dock auto-hide.")
            }
            try session.save(Journal(phase: .applied, original: original))
            try preferences.reload()
            return session
        } catch {
            let activationError = error
            do {
                _ = try session.stop()
            } catch {
                throw ToolError.invalid("\(activationError.localizedDescription) Dock restoration also failed. \(error.localizedDescription)")
            }
            throw activationError
        }
    }

    static func recover(in folder: URL, preferences: any PresentationDockPreferences) throws -> Restoration {
        let session = PresentationDockSession(folder: folder, preferences: preferences)
        guard FileManager.default.fileExists(atPath: session.journalURL.path) else { return .unchanged }
        try session.acquire()
        guard FileManager.default.fileExists(atPath: session.journalURL.path) else { return .unchanged }
        let data = try Data(contentsOf: session.journalURL)
        session.journal = try JSONDecoder().decode(Journal.self, from: data)
        return try session.stop()
    }

    public func stop() throws -> Restoration {
        defer { lease = nil }
        guard let journal else { return .unchanged }
        guard lease != nil else { throw ToolError.invalid("Use Dock recovery to retry restoration.") }
        let current = try preferences.read()
        if journal.phase == .preparing, !didWrite, current == .autoHidden {
            // A crash between writing and marking ownership cannot prove who
            // set the current value. Leave it intact.
            try clearJournal()
            return .uncertain
        }
        if current != .autoHidden {
            if current == journal.original, journal.phase == .restoring {
                // The previous restore may have written the setting and failed to
                // reload the Dock. A retry can finish without another write.
                try preferences.reload()
                try clearJournal()
                return .restored
            }
            try clearJournal()
            return journal.phase == .preparing && current == journal.original ? .unchanged : .changedElsewhere
        }
        try save(Journal(phase: .restoring, original: journal.original))
        guard try preferences.read() == .autoHidden else {
            try clearJournal()
            return .changedElsewhere
        }
        try preferences.write(journal.original)
        guard try preferences.read() == journal.original else {
            throw ToolError.invalid("The previous Dock setting could not be verified.")
        }
        try preferences.reload()
        try clearJournal()
        return .restored
    }

    public func relinquishIfChanged() throws -> Bool {
        guard try preferences.read() != .autoHidden else { return false }
        if journal != nil { try clearJournal() }
        lease = nil
        return true
    }

    private init(folder: URL, preferences: any PresentationDockPreferences) {
        self.folder = folder
        self.preferences = preferences
    }

    private var journalURL: URL { folder.appending(path: "dock-recovery.json") }

    private func acquire() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        lease = try PresentationSettingsLock(url: folder.appending(path: "dock.lock"))
    }

    private func save(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        self.journal = journal
    }

    private func clearJournal() throws {
        try FileManager.default.removeItem(at: journalURL)
        journal = nil
    }

    private static func recoveryFolder() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appending(path: "MacUtilityKit/Presentation", directoryHint: .isDirectory)
    }
}

private final class PresentationSettingsLock {
    private let handle: Int32

    init(url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ToolError.invalid("Could not open the Dock restoration lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ToolError.invalid("Another Mac Utility Kit session is managing Dock visibility.")
        }
        handle = descriptor
    }

    deinit { close(handle) }
}

@MainActor
private final class SystemPresentationDockPreferences: PresentationDockPreferences {
    private let domain = "com.apple.dock" as CFString
    private let key = "autohide" as CFString

    func read() throws -> PresentationDockValue {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw ToolError.invalid("Could not read the Dock setting.")
        }
        guard let value = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return .missing
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let enabled = value as? Bool else {
            throw ToolError.invalid("The Dock auto-hide setting uses an unsupported value.")
        }
        return enabled ? .autoHidden : .shown
    }

    func write(_ value: PresentationDockValue) throws {
        let property: CFPropertyList?
        switch value {
        case .missing: property = nil
        case .shown: property = kCFBooleanFalse
        case .autoHidden: property = kCFBooleanTrue
        }
        CFPreferencesSetValue(key, property, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw ToolError.invalid("Could not save the Dock setting.")
        }
    }

    func reload() throws {
        for dock in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
            if kill(dock.processIdentifier, SIGTERM) != 0, errno != ESRCH {
                throw ToolError.invalid("Could not reload the Dock.")
            }
        }
    }
}
