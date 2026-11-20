import AppKit
import SwiftUI
import UtilityCore

struct DocumentConvertControls: View {
    let inputs: [URL]
    @Binding var options: DocumentConvertOptions
    @State private var selected: URL?
    @State private var request: Request?
    @State private var sample: Measurement?

    private struct Request: Equatable {
        let id = UUID()
        let input: URL
        let options: DocumentConvertOptions
    }

    private struct Measurement {
        let request: Request
        let result: Result<DocumentConvert.Preview, any Error>
    }

    private var previewInput: URL? {
        selected.flatMap { inputs.contains($0) ? $0 : nil } ?? inputs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Output format") {
                Picker("Output format", selection: $options.target) {
                    ForEach(DocumentConvertOptions.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            if options.target == .plain {
                Text("Plain text keeps the words and removes styling and image content.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingRow("Filename") {
                TextField("Filename template", text: $options.filenamePattern)
                    .textFieldStyle(.roundedBorder)
                    .help("Use {name} for the source name and {index} for the file number.")
            }
            if let input = previewInput, let index = inputs.firstIndex(of: input),
               let name = try? DocumentConvert.outputStem(input, position: index + 1, options: options) {
                Text(name + "." + options.target.fileExtension).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            let conflicts = DocumentConvert.conflictingOutputFilenames(inputs, options: options)
            if !conflicts.isEmpty {
                DisclosureGroup("Potential filename conflicts · \(conflicts.count)") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add {index} to give each export a distinct name.")
                        ForEach(conflicts, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Conversion Engines") {
                VStack(alignment: .leading, spacing: 9) {
                    enginePicker("Pandoc", url: $options.pandocExecutable)
                    if options.pandocExecutable == nil {
                        ExternalEngineSetupButton(engine: .pandoc) { options.pandocExecutable = $0 }
                    }
                    enginePicker("LibreOffice", url: $options.libreOfficeExecutable)
                    if options.libreOfficeExecutable == nil {
                        ExternalEngineSetupButton(engine: .libreOffice) { options.libreOfficeExecutable = $0 }
                    }
                    Toggle("Prefer LibreOffice for compatible pairs", isOn: $options.prefersLibreOffice)
                    Text("Legacy Word files use LibreOffice. Markdown conversions use Pandoc except when wrapping plain text.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            availability
            preview
        }
        .task(id: request) {
            guard let request else { return }
            do {
                let generated = try await DocumentConvert.preview(request.input, options: request.options)
                try Task.checkCancellation()
                sample = Measurement(request: request, result: .success(generated))
            } catch {
                if !Task.isCancelled { sample = Measurement(request: request, result: .failure(error)) }
            }
            if self.request == request { self.request = nil }
        }
        .onChange(of: previewInput) { request = nil }
        .onChange(of: options) { request = nil }
    }

    @ViewBuilder
    private var availability: some View {
        let issues = inputs.enumerated().compactMap { index, input in
            DocumentConvert.exportIssue(for: input, position: index + 1, options: options).map { (input, $0) }
        }
        if !issues.isEmpty {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, entry in
                Text(inputs.count > 1 ? "\(entry.0.lastPathComponent) · \(entry.1)" : entry.1)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        if let input = previewInput, DocumentConvert.previewIssue(for: input, options: options) == nil,
           let engine = try? DocumentConvert.requiredEngine(for: input, options: options) {
            Text("Engine: \(engine.rawValue)").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if inputs.count > 1 {
            SettingRow("Preview file") {
                Picker("Preview file", selection: Binding(get: { previewInput }, set: { selected = $0 })) {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                        Text(input.lastPathComponent).tag(Optional(input))
                    }
                }
                .labelsHidden()
            }
        }
        HStack {
            Button("Preview Converted Text…", systemImage: "doc.text.magnifyingglass") {
                if let previewInput { request = Request(input: previewInput, options: options) }
            }
            .disabled(request != nil || previewInput.map {
                DocumentConvert.previewIssue(for: $0, options: options) != nil
            } ?? true)
            if request != nil {
                ProgressView().controlSize(.small)
                Button("Cancel") { request = nil }
            }
        }
        if let sample, sample.request.input == previewInput, sample.request.options == options, request == nil {
            switch sample.result {
            case .success(let preview):
                ScrollView {
                    Text(preview.text.isEmpty ? "The converted document contains no text." : preview.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 84, maxHeight: 230)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                if preview.truncated {
                    Text("Preview shows the first 20,000 characters.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .failure(let error):
                Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func enginePicker(_ name: String, url: Binding<URL?>) -> some View {
        HStack {
            Button("Choose \(name)…", systemImage: "gearshape") {
                let panel = NSOpenPanel()
                if panel.runModal() == .OK { url.wrappedValue = panel.url }
            }
            if let file = url.wrappedValue {
                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle).help(file.path)
                Button("Clear \(name)", systemImage: "xmark.circle") { url.wrappedValue = nil }
                    .labelStyle(.iconOnly)
            }
        }
    }
}
