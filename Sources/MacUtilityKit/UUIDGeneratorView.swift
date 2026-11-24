import SwiftUI
import UtilityCore

struct UUIDGeneratorDraft {
    var version: UUIDGenerator.Version = .random
    var count = "1"
    var uppercase = false
    var hyphenated = true
    var inspectionInput = ""
    var generated = ""
}

struct UUIDGeneratorView: View {
    @Binding var draft: UUIDGeneratorDraft
    @State private var issue: String?

    var body: some View {
        InteractiveToolLayout(tool: .uuidGenerator) { palette in
            WorkspaceSection("Generate", palette: palette) {
                SettingRow("Version") {
                    Picker("Version", selection: $draft.version) {
                        Text("v4 · Random").tag(UUIDGenerator.Version.random)
                        Text("v7 · Unix time").tag(UUIDGenerator.Version.timestamped)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                SettingRow("Count") {
                    TextField("Count", text: $draft.count)
                        .accessibilityLabel("Number of UUIDs")
                }
                Toggle("Uppercase", isOn: $draft.uppercase)
                Toggle("Include hyphens", isOn: $draft.hyphenated)
                Button("Generate", systemImage: "arrow.clockwise", action: generate)
                    .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                if let issue {
                    Text(issue).font(.callout).foregroundStyle(.red)
                }
            }
            if !draft.generated.isEmpty {
                WorkspaceSection("Generated UUIDs", palette: palette) {
                    ScrollView {
                        Text(draft.generated)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                    }
                    .frame(maxHeight: 180)
                    .workspaceInset(palette)
                    .accessibilityLabel("Generated UUIDs")
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(draft.generated) }
                        Button("Export…", systemImage: "square.and.arrow.up", action: export)
                    }
                }
            }
            WorkspaceSection("Inspect", palette: palette) {
                TextField("Paste a UUID or UUID URN", text: $draft.inspectionInput)
                    .font(.body.monospaced())
                if !draft.inspectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    switch Result(catching: { try UUIDGenerator.inspect(draft.inspectionInput) }) {
                    case .success(let inspection):
                        Text(inspection.canonicalUUID).font(.body.monospaced()).textSelection(.enabled)
                        LabeledContent("Variant", value: inspection.variant)
                        if let version = inspection.version {
                            LabeledContent("Version", value: String(version))
                        }
                        if let milliseconds = inspection.unixMilliseconds, let date = inspection.date {
                            LabeledContent("Unix milliseconds", value: String(milliseconds))
                            LabeledContent("Timestamp", value: date.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true)))
                        }
                        HStack {
                            Button("Copy UUID") { DeveloperToolFiles.copy(inspection.canonicalUUID) }
                            Button("Copy URN") { DeveloperToolFiles.copy(inspection.urn) }
                        }
                    case .failure(let error):
                        Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func generate() {
        guard let count = Int(draft.count.trimmingCharacters(in: .whitespacesAndNewlines)), (1...10_000).contains(count) else {
            issue = "Enter a whole number between 1 and 10,000."
            return
        }
        do {
            draft.generated = try UUIDGenerator.generate(
                draft.version, count: count, uppercase: draft.uppercase, hyphenated: draft.hyphenated
            ).joined(separator: "\n")
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func export() {
        do {
            try DeveloperToolFiles.save(Data((draft.generated + "\n").utf8), as: "UUIDs.txt")
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
