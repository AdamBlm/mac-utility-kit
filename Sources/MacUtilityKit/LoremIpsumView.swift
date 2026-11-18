import SwiftUI
import UtilityCore

struct LoremIpsumDraft {
    var unit: LoremIpsum.Unit = .paragraphs
    var format: LoremIpsum.Format = .plain
    var count = "3"
    var startsWithLorem = true
}

struct LoremIpsumView: View {
    @Binding var draft: LoremIpsumDraft
    @State private var output = ""
    @State private var generatedFormat: LoremIpsum.Format = .plain
    @State private var issue: String?

    var body: some View {
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
                    Button("Save…", systemImage: "square.and.arrow.up", action: save)
                        .disabled(output.isEmpty)
                }
                if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            }
            if !output.isEmpty {
                WorkspaceSection(generatedFormat.rawValue, palette: palette) {
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
            output = try LoremIpsum.generate(count: count, unit: draft.unit, format: draft.format,
                                            startsWithLorem: draft.startsWithLorem)
            generatedFormat = draft.format
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func save() {
        do {
            try DeveloperToolFiles.save(Data((output + "\n").utf8), as: "Lorem Ipsum." + generatedFormat.fileExtension)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
