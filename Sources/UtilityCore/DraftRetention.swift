import Darwin
import Foundation
import Observation

@MainActor
@Observable
package final class DraftRetention {
    package static let shared: DraftRetention = {
        let store = DraftRetention(defaults: .standard, file: storedFile)
        store.start()
        return store
    }()

    private struct Record: Codable {
        let text: String
        let updated: Date
    }

    private struct StoredRecords: Decodable {
        private struct ToolKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        let records: [String: Record]
        let count: Int

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: ToolKey.self)
            let keys = container.allKeys
            count = keys.count
            var decoded: [String: Record] = [:]
            for key in keys where DraftRetention.supportedToolIDs.contains(key.stringValue) {
                decoded[key.stringValue] = try? container.decode(Record.self, forKey: key)
            }
            records = decoded
        }
    }

    nonisolated private static let supportedToolIDs = Set([Tool.wordCounter.id, Tool.caseConverter.id])
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let storedFile = URL.applicationSupportDirectory
        .appending(path: "Mac Utility Kit", directoryHint: .isDirectory)
        .appending(path: "Drafts", directoryHint: .isDirectory)
        .appending(path: "Retained Text Drafts.json")
    private var pending: Task<Void, Never>?
    private var expiration: Task<Void, Never>?
    private var records: [String: Record]?

    private let defaults: UserDefaults
    private let file: URL
    private let removeFile: (URL) throws -> Void
    private let now: () -> Date
    private let retryDelay: Duration

    package static let preference = "drafts.keepsTextLocally"
    private static let pendingDeletionPreference = "drafts.pendingDeletion"

    package private(set) var issue: String?
    private var enabled: Bool { defaults.bool(forKey: Self.preference) }
    private var pendingDeletion: Bool { defaults.bool(forKey: Self.pendingDeletionPreference) }

    package init(defaults: UserDefaults, file: URL,
                 removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                 now: @escaping () -> Date = { .now }, retryDelay: Duration = .seconds(30)) {
        self.defaults = defaults
        self.file = file
        self.removeFile = removeFile
        self.now = now
        self.retryDelay = retryDelay
    }

    package func start() {
        if pendingDeletion || !enabled { try? clear() }
        else { load() }
    }

    package func setEnabled(_ value: Bool) {
        if !value { defaults.set(true, forKey: Self.pendingDeletionPreference) }
        defaults.set(value, forKey: Self.preference)
        if pendingDeletion { try? clear() }
        else if value { load() }
    }

    package func retained(for tool: Tool) -> String? {
        guard enabled, !pendingDeletion, Self.supportedToolIDs.contains(tool.id) else { return nil }
        load()
        guard let record = records?[tool.id], now().timeIntervalSince(record.updated) < maximumAge else { return nil }
        return record.text
    }

    package func record(_ text: String, for tool: Tool) {
        guard enabled, !pendingDeletion, Self.supportedToolIDs.contains(tool.id) else { return }
        load()
        if text.isEmpty || text.utf8.count > 262_144 {
            records?[tool.id] = nil
        } else {
            records?[tool.id] = Record(text: text, updated: now())
        }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
            self?.persist()
        }
    }

    package func clear() throws {
        defaults.set(true, forKey: Self.pendingDeletionPreference)
        pending?.cancel()
        expiration?.cancel()
        pending = nil
        expiration = nil
        records = [:]
        do {
            try removeStoredDrafts()
            defaults.removeObject(forKey: Self.pendingDeletionPreference)
            issue = nil
        } catch {
            issue = "Could not delete the retained drafts. \(error.localizedDescription)"
            scheduleRetry()
            throw error
        }
    }

    package func persist() {
        pending?.cancel()
        pending = nil
        if pendingDeletion { try? clear(); return }
        guard enabled else { return }
        load()
        let cutoff = now().addingTimeInterval(-maximumAge)
        records = records?.filter { $0.value.updated > cutoff }
        guard let records, !records.isEmpty else { try? clear(); return }
        do {
            try write(records)
            issue = nil
            scheduleExpiration()
        } catch {
            issue = "Could not update the retained drafts. \(error.localizedDescription)"
            scheduleRetry()
        }
    }

    private func write(_ records: [String: Record]) throws {
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
    }

    private func load() {
        guard records == nil else { return }
        let cutoff = now().addingTimeInterval(-maximumAge)
        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let encoded = size.flatMap { (0...4_194_304).contains($0) ? try? Data(contentsOf: file) : nil }
        let disk = encoded.flatMap { try? JSONDecoder().decode(StoredRecords.self, from: $0) }
        if encoded != nil, disk == nil {
            try? clear()
            return
        }
        records = (disk?.records ?? [:]).filter { _, record in
            record.updated > cutoff && record.text.utf8.count <= 262_144
        }
        if let disk, disk.count != records?.count { persist() }
        else { scheduleExpiration() }
    }

    private func scheduleExpiration() {
        expiration?.cancel()
        expiration = nil
        guard let updated = records?.values.map(\.updated).min() else { return }
        let delay = max(0.1, updated.addingTimeInterval(maximumAge).timeIntervalSince(now()))
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            self?.persist()
        }
    }

    private func scheduleRetry() {
        expiration?.cancel()
        expiration = Task { [weak self, retryDelay] in
            do { try await Task.sleep(for: retryDelay) }
            catch { return }
            self?.persist()
        }
    }

    private func removeStoredDrafts() throws {
        do { try removeFile(file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}
