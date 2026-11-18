import AppKit
import SwiftUI
import UtilityCore

struct PDFToWordControls: View {
    let inputs: [URL]
    @Binding var options: PDFToWordOptions

    @State private var chosen: URL?
    @State private var preview: PDFToWord.Preview?
    @State private var previewPage = 0
    @State private var job: Task<Void, Never>?
    @State private var jobID: UUID?
    @State private var progress: Double?
    @State private var error: String?

    private var source: URL? {
        if let chosen, inputs.contains(chosen) { return chosen }
        return inputs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            optionsControls
                .disabled(job != nil)
            if let source, let issue = PDFToWord.optionIssue(source, options: options) {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
            previewControls
        }
        .onChange(of: options) { resetPreview() }
        .onChange(of: source) { resetPreview() }
        .onDisappear { job?.cancel() }
    }

    private var optionsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow("Conversion") {
                Picker("Conversion", selection: $options.mode) {
                    ForEach(PDFToWordOptions.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(options.mode == .flowing
                 ? "Rebuilds editable paragraphs, common headings, and lists. Use Preserve Layout to retain supported figures."
                 : "Rebuilds positioned text and supported figures. Complex tables, forms, and font matching can change.")
                .font(.callout).foregroundStyle(.secondary)
            SettingRow("Page range") {
                TextField("All, or 1–3, 5", text: $options.pages).textFieldStyle(.roundedBorder)
            }
            SettingRow("PDF password") {
                SecureField("If required", text: $options.password).textFieldStyle(.roundedBorder)
            }
            Toggle("Recognize text on scanned pages", isOn: $options.recognizeScans)
            HStack {
                Button("Choose LibreOffice…", systemImage: "gearshape", action: chooseLibreOffice)
                if let executable = options.libreOfficeExecutable {
                    Text(executable.lastPathComponent).lineLimit(1).help(executable.path)
                    Button("Clear LibreOffice", systemImage: "xmark.circle") { options.libreOfficeExecutable = nil }
                        .labelStyle(.iconOnly)
                }
            }
        }
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if inputs.count > 1 {
                SettingRow("Preview file") {
                    Picker("Preview file", selection: Binding(get: { source }, set: { chosen = $0 })) {
                        ForEach(inputs, id: \.self) { file in Text(file.lastPathComponent).tag(Optional(file)) }
                    }
                    .labelsHidden()
                    .disabled(job != nil)
                }
            }
            HStack {
                Button("Preview Text…", systemImage: "doc.viewfinder", action: makePreview)
                    .disabled(job != nil || source == nil)
                if job != nil {
                    if let progress {
                        ProgressView(value: progress).frame(width: 130).accessibilityLabel("Reading pages")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { job?.cancel() }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let preview, preview.pages.indices.contains(previewPage) {
                let page = preview.pages[previewPage]
                Stepper("PDF page \(page.id)", value: $previewPage, in: 0...(preview.pages.count - 1))
                    .font(.callout)
                if page.usedOCR {
                    Text("Recognized text").font(.caption).foregroundStyle(.secondary)
                }
                if let issue = page.issue {
                    Text(issue).font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(page.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            .font(.callout)
                    }
                    .frame(maxHeight: 190)
                }
                ForEach(preview.warnings, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseLibreOffice() {
        let panel = NSOpenPanel()
        panel.message = "Choose LibreOffice.app or the soffice executable."
        if panel.runModal() == .OK { options.libreOfficeExecutable = panel.url }
    }

    private func makePreview() {
        guard let source, job == nil else { return }
        resetPreview()
        let settings = options
        let id = UUID()
        jobID = id
        job = Task {
            defer {
                if jobID == id {
                    job = nil
                    jobID = nil
                    progress = nil
                }
            }
            do {
                let result = try await PDFToWord.preview(source, options: settings) { fraction in
                    await MainActor.run {
                        if jobID == id { progress = fraction }
                    }
                }
                try Task.checkCancellation()
                if jobID == id { preview = result }
            } catch is CancellationError {
            } catch {
                if jobID == id { self.error = error.localizedDescription }
            }
        }
    }

    private func resetPreview() {
        job?.cancel()
        preview = nil
        previewPage = 0
        error = nil
    }
}
