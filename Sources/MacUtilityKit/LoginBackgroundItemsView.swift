import AppKit
import ServiceManagement
import SwiftUI
import UtilityCore

struct LoginBackgroundItemsView: View {
    @State private var entries: [LoginBackgroundItems.Entry]?
    @State private var error: String?
    @State private var query = ""
    @State private var kind: LoginBackgroundItems.Kind?
    @State private var status: LoginBackgroundItems.Status?
    @State private var task: Task<Void, Never>?
    @State private var lastUpdated: Date?
    @State private var refreshAfterSettings = false

    private var matches: [LoginBackgroundItems.Entry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (entries ?? []).filter { entry in
            guard kind == nil || kind == entry.kind, status == nil || status == entry.status else { return false }
            return search.isEmpty || [entry.name, entry.publisher, entry.team, entry.identifier, entry.sourcePath, entry.executablePath]
                .compactMap { $0 }.contains { $0.localizedStandardContains(search) }
        }
    }

    var body: some View {
        InteractiveToolLayout(tool: .loginBackgroundItems) { palette in
            WorkspaceSection("Inventory", palette: palette) {
                HStack {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refresh).disabled(task != nil)
                    Button("Manage in System Settings", systemImage: "gearshape") {
                        refreshAfterSettings = true
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    Spacer()
                    if task != nil {
                        ProgressView().controlSize(.small).accessibilityLabel("Refreshing items")
                        Button("Cancel", action: cancel)
                    }
                }
                Text("This inventory shows items macOS reports for your account or the system. Status reflects registration and policy.")
                    .foregroundStyle(.secondary)
                if let lastUpdated {
                    Text("Last updated \(lastUpdated, format: .dateTime.hour().minute().second())")
                        .foregroundStyle(.secondary).font(.callout)
                }
                if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            }

            if let entries {
                WorkspaceSection("Items", palette: palette) {
                    TextField("Search names, publishers, or paths", text: $query)
                    HStack {
                        Picker("Type", selection: $kind) {
                            Text("All types").tag(LoginBackgroundItems.Kind?.none)
                            ForEach(LoginBackgroundItems.Kind.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(Optional(type))
                            }
                        }
                        Picker("Status", selection: $status) {
                            Text("Any status").tag(LoginBackgroundItems.Status?.none)
                            ForEach(LoginBackgroundItems.Status.allCases, id: \.self) { value in
                                Text(value.rawValue).tag(Optional(value))
                            }
                        }
                    }
                    if matches.isEmpty {
                        Text(entries.isEmpty ? "macOS reported no matching item types." : "No items match your filters.")
                            .foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(matches) { entry in entryRow(entry) }
                    }
                }
            }
        }
        .onAppear { if entries == nil { refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if refreshAfterSettings {
                refreshAfterSettings = false
                cancel()
                refresh()
            }
        }
        .onDisappear(perform: cancel)
    }

    private func entryRow(_ entry: LoginBackgroundItems.Entry) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                entryDetail("Publisher reported by macOS", entry.publisher ?? "Unknown publisher")
                if let team = entry.team { entryDetail("Developer team", team) }
                if let identifier = entry.identifier { entryDetail("Identifier", identifier) }
                entryDetail("Scope", entry.systemWide ? "System" : "Current account")
                entryDetail("Source", entry.sourcePath ?? "Unknown source path")
                if let executable = entry.executablePath { entryDetail("Executable", executable) }
                if let location = entry.location {
                    if entry.locationExists {
                        Button("Reveal in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([location])
                        }
                    } else {
                        Text("File is missing or unavailable.").foregroundStyle(.secondary)
                    }
                } else if entry.sourcePath != nil || entry.executablePath != nil {
                    Text("macOS only reports a partial path for this item.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.vertical, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).fontWeight(.medium).lineLimit(1)
                    Text(entry.publisher ?? "Unknown publisher").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(entry.status.rawValue)
                    Text(entry.kind.rawValue).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }

    private func entryDetail(_ label: String, _ value: String) -> some View {
        SettingRow(label) {
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func refresh() {
        guard task == nil else { return }
        error = nil
        task = Task {
            do {
                let updated = try await LoginBackgroundItems.inventory()
                try Task.checkCancellation()
                entries = updated
                lastUpdated = Date()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            task = nil
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }
}
