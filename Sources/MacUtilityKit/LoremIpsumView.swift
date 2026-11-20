import SwiftUI
import UtilityCore

struct LoremIpsumDraft {
    var unit: LoremIpsum.Unit = .paragraphs
    var format: LoremIpsum.Format = .plain
    var count = "3"
    var startsWithLorem = true
    var document: LoremIpsum.Document?
}

struct LoremIpsumView: View {
    @Binding var draft: LoremIpsumDraft
    @State private var issue: String?

    var body: some View {
        let format = draft.format
        let output = draft.document?.rendered(as: format) ?? ""
        InteractiveToolLayout(tool: .loremIpsum) { palette in
            WorkspaceSection("Generate", palette: palette) {
                SettingRow("Unit") {
                    Picker("Unit", selection: $draft.unit) {
                        ForEach(LoremIpsum.Unit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                SettingRow("Count") {
                    TextField("Count", text: $draft.count)
                }
                SettingRow("Format") {
                    Picker("Format", selection: $draft.format) {
                        ForEach(LoremIpsum.Format.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                Toggle("Start with Lorem ipsum", isOn: $draft.startsWithLorem)
                HStack {
                    Button(output.isEmpty ? "Generate" : "Regenerate", systemImage: "arrow.clockwise", action: generate)
                        .buttonStyle(.borderedProminent)
                    Button("Copy", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(output) }
                        .disabled(output.isEmpty)
                    Button("Save…", systemImage: "square.and.arrow.up") { save(output, format: format) }
                        .disabled(output.isEmpty)
                }
                if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            }
            if !output.isEmpty {
                WorkspaceSection(format.rawValue, palette: palette) {
                    ScrollView {
                        Text(output).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
    }

    private func generate() {
        do {
            let count = Int(draft.count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            draft.document = try LoremIpsum.document(count: count, unit: draft.unit, startsWithLorem: draft.startsWithLorem)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func save(_ output: String, format: LoremIpsum.Format) {
        do {
            try DeveloperToolFiles.save(Data((output + "\n").utf8), as: "Lorem Ipsum." + format.fileExtension)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
