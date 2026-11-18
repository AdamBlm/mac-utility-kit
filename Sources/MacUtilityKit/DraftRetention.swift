import Darwin
import Foundation
import SwiftUI
import UtilityCore

@MainActor
final class DraftRetention {
    static let shared = DraftRetention()

    private struct Record: Codable {
        let text: String
        let updated: Date
    }

    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private lazy var file = URL.applicationSupportDirectory
        .appending(path: "Mac Utility Kit", directoryHint: .isDirectory)
        .appending(path: "Drafts", directoryHint: .isDirectory)
        .appending(path: "Retained Text Drafts.json")
    private var pending: Task<Void, Never>?
    private var expiration: Task<Void, Never>?
    private var records: [String: Record]?

    static let preference = "drafts.keepsTextLocally"

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.preference) }

    func retained(for tool: Tool) -> String? {
        guard enabled, supports(tool) else { return nil }
        load()
        guard let record = records?[tool.id], Date.now.timeIntervalSince(record.updated) <= maximumAge else { return nil }
        return record.text
    }

    func record(_ text: String, for tool: Tool) {
        guard enabled, supports(tool) else { return }
        load()
        if text.isEmpty || text.utf8.count > 262_144 {
            records?[tool.id] = nil
        } else {
            records?[tool.id] = Record(text: text, updated: .now)
        }
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
            persist()
        }
    }

    func clear() throws {
        pending?.cancel()
        expiration?.cancel()
        pending = nil
        expiration = nil
        records = [:]
        try removeStoredDrafts()
    }

    func persist() {
        pending?.cancel()
        pending = nil
        guard enabled else { return }
        load()
        let lowerBound = Date.now.addingTimeInterval(-maximumAge)
        records = records?.filter { $0.value.updated > lowerBound }
        scheduleExpiration()
        guard let records, !records.isEmpty else {
            try? removeStoredDrafts()
            return
        }
        do {
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let temporary = folder.appending(path: ".drafts-" + UUID().uuidString)
            let encoded = try JSONEncoder().encode(records)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: encoded)
            try handle.close()
            guard rename(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
        } catch {
            // The current session's draft remains available if persistence fails.
        }
    }

    private func load() {
        guard records == nil else { return }
        let cutoff = Date.now.addingTimeInterval(-maximumAge)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let encoded = (1...4_194_304).contains(size) ? try? Data(contentsOf: file) : nil
        let disk = encoded.flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
        records = disk.filter { $0.value.updated >= cutoff && $0.value.text.utf8.count <= 262_144 }
        if disk.count != records?.count { persist() }
        else { scheduleExpiration() }
    }

    private func scheduleExpiration() {
        expiration?.cancel()
        expiration = nil
        guard let updated = records?.values.map(\.updated).min() else { return }
        let delay = max(0.1, updated.addingTimeInterval(maximumAge).timeIntervalSinceNow)
        expiration = Task {
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            persist()
        }
    }

    private func removeStoredDrafts() throws {
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    private func supports(_ tool: Tool) -> Bool {
        tool == .wordCounter || tool == .caseConverter
    }
}

struct DraftRetentionPreference: View {
    @AppStorage(DraftRetention.preference) private var enabled = false
    @State private var issue: String?

    var body: some View {
        Toggle("Keep Word Counter and Case Converter drafts for 7 days", isOn: Binding(get: { enabled }, set: { value in
            enabled = value
            if !value { clear() }
        }))
        if enabled || issue != nil { Button("Clear Retained Drafts", action: clear) }
        if let issue { Text(issue).foregroundStyle(.secondary) }
    }

    private func clear() {
        do {
            try DraftRetention.shared.clear()
            issue = nil
        } catch {
            issue = "Could not delete the retained drafts. \(error.localizedDescription)"
        }
    }
}
