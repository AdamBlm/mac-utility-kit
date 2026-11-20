import Foundation
import SwiftUI
import UtilityCore

@MainActor @Observable
final class VideoEngineSettings {
    static let shared = VideoEngineSettings()

    private let manager: VideoEngineManager?
    private(set) var installed: ManagedVideoEngines?
    private(set) var progress: String?
    var error: String?

    var available: Bool { manager != nil }

    private init() {
        let bundle = Bundle.main
        guard let address = bundle.object(forInfoDictionaryKey: "MUKVideoEngineFeed") as? String,
              let feed = URL(string: address),
              let encodedKey = bundle.object(forInfoDictionaryKey: "MUKVideoEnginePublicKey") as? String,
              let key = Data(base64Encoded: encodedKey) else {
            manager = nil
            return
        }
        let root = URL.applicationSupportDirectory
            .appendingPathComponent(bundle.bundleIdentifier ?? "app.macutilitykit.preview")
            .appendingPathComponent("VideoEngines")
        manager = try? VideoEngineManager(root: root, feed: feed, publicKey: key)
    }

    func refresh() async {
        do { installed = try await manager?.installed() }
        catch { self.error = error.localizedDescription }
    }

    func install(repair: Bool = false) async throws -> ManagedVideoEngines {
        guard let manager else { throw ToolError.invalid("Managed Video Tools are unavailable in this build.") }
        guard progress == nil else { throw ToolError.invalid("Video Tools setup is already running.") }
        progress = "Checking Video Tools…"
        defer { progress = nil }
        let engines = try await manager.install(repair: repair) { [weak self] name, index, count, bytes in
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            await MainActor.run { self?.progress = "Installing \(name) (\(index + 1) of \(count), \(size) total)…" }
        }
        installed = engines
        return engines
    }

    func updateAutomatically() async {
        let preferences = UserDefaults.standard
        guard installed != nil, preferences.bool(forKey: "automaticallyUpdateVideoTools"),
              Date().timeIntervalSince1970 - preferences.double(forKey: "lastAutomaticVideoToolsCheck") > 86_400,
              progress == nil else { return }
        preferences.set(Date().timeIntervalSince1970, forKey: "lastAutomaticVideoToolsCheck")
        _ = try? await install()
    }

    func rollback() async throws {
        try await manager?.rollback()
        UserDefaults.standard.set(false, forKey: "automaticallyUpdateVideoTools")
        await refresh()
    }

    func remove() async throws {
        try await manager?.remove()
        await refresh()
    }
}

struct VideoEngineSettingsView: View {
    private let engines = VideoEngineSettings.shared
    @AppStorage("automaticallyUpdateVideoTools") private var automaticUpdates = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Video Tools") {
                if let installed = engines.installed {
                    ForEach(installed.versions.keys.sorted(), id: \.self) { name in
                        LabeledContent(name) {
                            HStack {
                                Text(installed.versions[name, default: ""])
                                if let notices = installed.notices[name] { Link("License", destination: notices) }
                                if let source = installed.sources[name] { Link("Source", destination: source) }
                            }
                        }
                    }
                } else {
                    Text(engines.available ? "Video Tools are not installed." : "Managed setup is unavailable in this build.")
                }
                if engines.available {
                    Toggle("Automatically update installed Video Tools", isOn: $automaticUpdates)
                        .disabled(engines.installed == nil)
                    HStack {
                        Button(engines.installed == nil ? "Install Video Tools" : "Check for Updates") {
                            run { _ = try await engines.install() }
                        }
                        if engines.installed != nil {
                            Button("Repair") { run { _ = try await engines.install(repair: true) } }
                            Button("Rollback") { run { try await engines.rollback() } }
                            Button("Remove") { run { try await engines.remove() } }
                        }
                    }
                    .disabled(task != nil || engines.progress != nil)
                }
                if let progress = engines.progress {
                    HStack {
                        ProgressView(progress).controlSize(.small)
                        if let task { Button("Cancel") { task.cancel() } }
                    }
                }
                if let error = engines.error { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 240)
        .task { await engines.refresh() }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        engines.error = nil
        task = Task {
            defer { task = nil }
            do { try await operation() }
            catch { if !Task.isCancelled { engines.error = error.localizedDescription } }
        }
    }
}
