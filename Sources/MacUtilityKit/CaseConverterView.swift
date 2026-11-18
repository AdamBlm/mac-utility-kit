import SwiftUI
import UtilityCore

struct CaseConverterDraft {
    var input = ""
    var style = TextCase.snake
    var localeID = ""
    var useLineSelection = false
    var lines = ""
}

struct CaseConverterView: View {
    @Binding var draft: CaseConverterDraft
    @State private var output = ""
    @State private var issue: String?

    var body: some View {
        InteractiveToolLayout(tool: .caseConverter) { palette in
            WorkspaceSection("Text", palette: palette) {
                TextEditor(text: Binding(get: { draft.input }, set: {
                    draft.input = $0
                    clear()
                }))
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Text to convert")
                SettingRow("Case") {
                    Picker("Case", selection: $draft.style) {
                        ForEach(TextCase.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                SettingRow("Locale") {
                    Picker("Locale", selection: $draft.localeID) {
                        Text("System Locale").tag("")
                        Text("English").tag("en")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Greek").tag("el")
                        Text("Lithuanian").tag("lt")
                        Text("Turkish").tag("tr")
                        Text("Azerbaijani").tag("az")
                    }
                    .labelsHidden()
                }
                Toggle("Convert selected lines", isOn: $draft.useLineSelection)
                if draft.useLineSelection {
                    TextField("Lines, e.g. 1, 3–5", text: $draft.lines)
                }
                Button("Convert", systemImage: "textformat", action: convert)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.input.isEmpty)
                if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            }
            if !output.isEmpty {
                WorkspaceSection("Result", palette: palette) {
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(output) }
                        Button("Save…", systemImage: "square.and.arrow.up", action: save)
                    }
                    ScrollView {
                        Text(output)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
        .onChange(of: draft.style) { clear() }
        .onChange(of: draft.localeID) { clear() }
        .onChange(of: draft.useLineSelection) { clear() }
        .onChange(of: draft.lines) { clear() }
    }

    private func clear() {
        output = ""
        issue = nil
    }

    private func convert() {
        do {
            let locale = draft.localeID.isEmpty ? Locale.current : Locale(identifier: draft.localeID)
            output = try CaseConverter.convert(
                draft.input, to: draft.style, locale: locale, selectedLines: draft.useLineSelection ? draft.lines : nil
            )
            issue = output.isEmpty ? "No text remains after conversion." : nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func save() {
        do {
            try DeveloperToolFiles.save(Data(output.utf8), as: "Converted Text.txt")
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}
