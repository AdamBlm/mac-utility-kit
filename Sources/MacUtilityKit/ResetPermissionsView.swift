import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ResetPermissionsView: View {
    @State private var target: PermissionResetTarget?
    @State private var category = ResetPermissionCategory.camera
    @State private var confirmed: Request?
    @State private var active: Request?
    @State private var status: String?

    private struct Request: Equatable {
        let target: PermissionResetTarget
        let category: ResetPermissionCategory
    }

    var body: some View {
        InteractiveToolLayout(tool: .resetPermissions) { palette in
            WorkspaceSection("Application", palette: palette) {
                Button("Choose App…", systemImage: "folder", action: choose)
                    .disabled(active != nil)
                if let target {
                    Text(target.name).font(.headline)
                    Text(target.bundleIdentifier)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingRow("Permission") {
                    Picker("Permission", selection: $category) {
                        ForEach(ResetPermissionCategory.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(active != nil)
                }
                if let target {
                    Text("Reset \(category.title) for \(target.name). The app may ask for access again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                WorkspaceFlowLayout {
                    Button("Reset Permission…", systemImage: "arrow.counterclockwise") {
                        if let target { confirmed = Request(target: target, category: category) }
                    }
                    .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                    .disabled(target == nil || active != nil)
                    Button("Open Privacy Settings", systemImage: "gearshape") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    if active != nil { ProgressView().controlSize(.small) }
                }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("Reset permission?", isPresented: Binding(get: { confirmed != nil }, set: { shown in
            if !shown { confirmed = nil }
        }), titleVisibility: .visible, presenting: confirmed) { request in
            Button("Reset \(request.category.title)", role: .destructive) {
                active = request
                status = nil
                Task { await reset(request) }
            }
        } message: { request in
            Text("\(request.target.name) · \(request.target.bundleIdentifier)")
        }
    }

    private func choose() {
        guard let url = DeveloperToolFiles.choose(allowedTypes: [.applicationBundle]) else { return }
        do {
            target = try ResetPermissions.inspect(url)
            status = nil
        } catch {
            target = nil
            status = error.localizedDescription
        }
    }

    private func reset(_ request: Request) async {
        defer { active = nil }
        do {
            try await ResetPermissions.reset(request.target, category: request.category)
            status = "macOS reset \(request.category.title) for \(request.target.name)."
        } catch {
            status = error.localizedDescription
        }
    }
}
