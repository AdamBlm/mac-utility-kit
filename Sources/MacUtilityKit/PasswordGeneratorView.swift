import AppKit
import SwiftUI
import UtilityCore

struct PasswordGeneratorView: View {
    private enum Mode: String, CaseIterable {
        case password = "Password"
        case passphrase = "Passphrase"
    }

    @State private var mode = Mode.password
    @State private var length = 20
    @State private var groups = Set(PasswordGenerator.CharacterGroup.allCases)
    @State private var requiresEachGroup = true
    @State private var excludesAmbiguous = false
    @State private var wordCount = 6
    @State private var separator = PasswordGenerator.Separator.hyphen
    @State private var capitalized = false
    @State private var generated: PasswordGenerator.Generated?
    @State private var revealed = false
    @State private var issue: String?

    var body: some View {
        InteractiveToolLayout(tool: .passwordGenerator) { palette in
            WorkspaceSection("Options", palette: palette) {
                Picker("Type", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch mode {
                case .password:
                    Stepper("Length: \(length)", value: $length, in: 4...128)
                    ForEach(PasswordGenerator.CharacterGroup.allCases) { group in
                        Toggle(group.rawValue, isOn: groupBinding(group))
                    }
                    Toggle("Include every selected group", isOn: $requiresEachGroup)
                    Toggle("Exclude visually similar characters", isOn: $excludesAmbiguous)
                case .passphrase:
                    Stepper("Words: \(wordCount)", value: $wordCount, in: 3...16)
                    SettingRow("Separator") {
                        Picker("Separator", selection: $separator) {
                            ForEach(PasswordGenerator.Separator.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                    Toggle("Capitalize each word", isOn: $capitalized)
                }
                Button("Generate", systemImage: "key", action: generate)
                    .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            }
            if let generated {
                WorkspaceSection("Generated Secret", palette: palette) {
                    Text(revealed ? generated.value : String(repeating: "•", count: min(generated.value.count, 28)))
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .workspaceInset(palette)
                        .accessibilityLabel(revealed ? generated.value : "Hidden generated secret")
                    Text("\(Int(generated.entropyBits.rounded(.down))) bits of randomness")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(revealed ? "Hide" : "Reveal", systemImage: revealed ? "eye.slash" : "eye") { revealed.toggle() }
                        Button("Copy", systemImage: "doc.on.doc") { copySecret(generated.value) }
                    }
                }
            }
        }
        .onChange(of: mode) { clearSecret() }
        .onChange(of: length) { clearSecret() }
        .onChange(of: groups) { clearSecret() }
        .onChange(of: requiresEachGroup) { clearSecret() }
        .onChange(of: excludesAmbiguous) { clearSecret() }
        .onChange(of: wordCount) { clearSecret() }
        .onChange(of: separator) { clearSecret() }
        .onChange(of: capitalized) { clearSecret() }
        .onDisappear(perform: clearSecret)
    }

    private func groupBinding(_ group: PasswordGenerator.CharacterGroup) -> Binding<Bool> {
        Binding(get: { groups.contains(group) }, set: { included in
            if included { groups.insert(group) } else { groups.remove(group) }
        })
    }

    private func generate() {
        clearSecret()
        do {
            switch mode {
            case .password:
                generated = try PasswordGenerator.password(length: length, groups: groups,
                                                           requiresEachGroup: requiresEachGroup, excludesAmbiguous: excludesAmbiguous)
            case .passphrase:
                generated = try PasswordGenerator.passphrase(wordCount: wordCount, separator: separator, capitalized: capitalized)
            }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func clearSecret() {
        generated = nil
        revealed = false
        issue = nil
    }

    private func copySecret(_ value: String) {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        if !ConcealedClipboard.write(item) {
            issue = "Could not copy the generated secret."
        }
    }
}
