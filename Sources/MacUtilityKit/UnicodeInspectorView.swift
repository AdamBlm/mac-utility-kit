import SwiftUI
import UtilityCore

private enum UnicodeInspectorMode: String, CaseIterable {
    case graphemes = "Graphemes"
    case scalars = "Code Points"
}

struct UnicodeInspectorDraft {
    var text = ""
    fileprivate var mode = UnicodeInspectorMode.graphemes
    var normalization = UnicodeInspector.Normalization.nfc
    var showsNormalization = false
}

struct UnicodeInspectorView: View {
    @Binding var draft: UnicodeInspectorDraft
    @State private var rowLimit = 100
    @State private var editorRevision = 0

    var body: some View {
        InteractiveToolLayout(tool: .unicodeInspector) { palette in
            WorkspaceSection("Text", palette: palette) {
                TextEditor(text: $draft.text)
                    .id(editorRevision)
                    .font(.body.monospaced())
                    .frame(minHeight: 105)
                    .accessibilityLabel("Text to inspect")
                if !draft.text.isEmpty {
                    Text("\(draft.text.count) graphemes · \(draft.text.unicodeScalars.count) code points · \(draft.text.utf8.count) UTF-8 bytes")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !draft.text.isEmpty {
                WorkspaceSection("Inspection", palette: palette) {
                    Picker("Inspection view", selection: $draft.mode) {
                        ForEach(UnicodeInspectorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    inspectionRows
                    if rowLimit < (draft.mode == .graphemes ? draft.text.count : draft.text.unicodeScalars.count) {
                        Button("Show 100 more") { rowLimit += 100 }
                    }
                    Text(UnicodeInspector.confusables == nil
                         ? "Unicode lookalike data is unavailable."
                         : "Possible lookalikes use Unicode \(UnicodeInspector.confusablesVersion) data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                WorkspaceSection("Normalization", palette: palette) {
                    DisclosureGroup("Preview NFC or NFD", isExpanded: $draft.showsNormalization) {
                        if draft.showsNormalization { normalizationPreview }
                    }
                }
            }
        }
        .onChange(of: draft.mode) { rowLimit = 100 }
        .onChange(of: draft.text.utf8.count) { rowLimit = 100 }
    }

    @ViewBuilder
    private var inspectionRows: some View {
        if draft.mode == .graphemes {
            ForEach(Array(draft.text.prefix(rowLimit).enumerated()), id: \.offset) { index, character in
                let grapheme = UnicodeInspector.Grapheme(value: character)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(index + 1) · \(grapheme.display)").font(.body.monospaced())
                    Text("UTF-8 \(grapheme.utf8)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if character.unicodeScalars.contains(where: { UnicodeInspector.confusables?[$0] != nil }) {
                        Label("Possible lookalike", systemImage: "character.magnify")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("\(character.unicodeScalars.count) code points") {
                        let scalars = grapheme.scalars
                        ForEach(Array(scalars.prefix(100).enumerated()), id: \.offset) { _, scalar in
                            scalarDetails(scalar)
                        }
                        if scalars.count > 100 {
                            Text("Use Code Points to inspect the remaining scalars.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                .textSelection(.enabled)
                Divider()
            }
        } else {
            ForEach(Array(draft.text.unicodeScalars.prefix(rowLimit).enumerated()), id: \.offset) { index, value in
                scalarDetails(UnicodeInspector.Scalar(value: value))
                    .accessibilityHint("Code point \(index + 1)")
                Divider()
            }
        }
    }

    private func scalarDetails(_ scalar: UnicodeInspector.Scalar) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(scalar.display) · \(scalar.codePoint)").font(.body.monospaced())
            Text("\(scalar.name) · \(scalar.category)").font(.callout)
            Text("UTF-8 \(scalar.utf8)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if let prototype = UnicodeInspector.confusables?[scalar.value] {
                let label = prototype.unicodeScalars.map { UnicodeInspector.Scalar(value: $0).display }.joined()
                Text("Possible lookalike · \(label)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private var normalizationPreview: some View {
        let result = draft.normalization.apply(to: draft.text)
        let changed = !result.utf8.elementsEqual(draft.text.utf8)
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Form", selection: $draft.normalization) {
                ForEach(UnicodeInspector.Normalization.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            let sample = result.unicodeScalars.prefix(100)
            Text(sample.map { UnicodeInspector.Scalar(value: $0).codePoint }.joined(separator: " "))
                .font(.caption.monospaced()).textSelection(.enabled)
            if result.unicodeScalars.count > sample.count {
                Text("Showing the first 100 code points. Actions use the full text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy \(draft.normalization.rawValue)") { DeveloperToolFiles.copy(result) }
                Button("Apply to Text") {
                    draft.text = result
                    editorRevision += 1
                }
                    .disabled(!changed)
                if !changed { Text("Already normalized").font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}
