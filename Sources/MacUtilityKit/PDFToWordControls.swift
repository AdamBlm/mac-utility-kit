import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFToWordControls: View {
    let inputs: [URL]
    @Binding var options: PDFToWordOptions

    private struct SourceRequest: Equatable {
        let input: URL
        let password: String
        let revision: UUID
    }

    @State private var reloadRevision = UUID()
    @State private var requestedReload: URL?
    @State private var chosen: URL?
    @State private var sourceDocument: (request: SourceRequest, result: Result<PDFDocument, any Error>)?
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
        let request = source.map { SourceRequest(input: $0, password: options.password, revision: reloadRevision) }
        VStack(alignment: .leading, spacing: 12) {
            optionsControls
                .disabled(job != nil)
            exportAvailability
            previewControls(request)
        }
        .task(id: request) {
            guard let request else { sourceDocument = nil; return }
            let acceptsReplacement = requestedReload == request.input
            requestedReload = nil
            do {
                if !acceptsReplacement { try PDFToWord.verifyReviewedSource(request.input, options: options) }
                let reviewed = try await PDFToWord.previewDocument(request.input, password: request.password)
                try Task.checkCancellation()
                if !acceptsReplacement {
                    try PDFToWord.verifyReviewedSource(request.input, options: options, stamp: reviewed.stamp)
                }
                options.reviewedSources[request.input] = reviewed.stamp
                sourceDocument = (request, .success(reviewed.document))
            } catch {
                guard !Task.isCancelled else { return }
                sourceDocument = (request, .failure(error))
            }
        }
        .onChange(of: options) { resetPreview() }
        .onChange(of: source) { resetPreview() }
        .onDisappear { job?.cancel() }
    }

    @ViewBuilder
    private var exportAvailability: some View {
        let issues = inputs.enumerated().compactMap { index, input in
            PDFToWord.optionIssue(input, options: options).map { (index: index, input: input, message: $0) }
        }
        if let first = issues.first, issues.count == inputs.count,
           issues.allSatisfy({ $0.message == first.message }) {
            Text(first.message).font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(issues, id: \.index) { issue in
                Text("\(issue.input.lastPathComponent) · \(issue.message)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
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

    private func previewControls(_ request: SourceRequest?) -> some View {
        let available = sourceDocument?.request == request ? sourceDocument?.result : nil
        let isStale = request.map {
            (try? PDFToWord.verifyReviewedSource($0.input, options: options)) == nil
        } ?? false
        return VStack(alignment: .leading, spacing: 9) {
            if inputs.count > 1 {
                SettingRow("Preview file") {
                    Picker("Preview file", selection: Binding(get: { source }, set: { chosen = $0 })) {
                        ForEach(inputs, id: \.self) { file in Text(file.lastPathComponent).tag(Optional(file)) }
                    }
                    .labelsHidden()
                    .disabled(job != nil)
                }
            }
            if inputs.count > 1 {
                Text("The page range applies to all PDFs in the batch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let request {
                Button("Reload Page Thumbnails", systemImage: "arrow.clockwise") {
                    resetPreview()
                    requestedReload = request.input
                    reloadRevision = UUID()
                }
                .disabled(job != nil)
            }
            if !isStale, case .success(let document) = available {
                PDFExportPagePicker(document: document, range: $options.pages, startsWithAll: true)
                    .disabled(job != nil)
            } else {
                SettingRow("Page range") {
                    TextField("All, or 1–3, 5", text: $options.pages)
                        .disabled(job != nil)
                }
                if !isStale, case .failure(let failure) = available {
                    Text(failure.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Preview Text…", systemImage: "doc.viewfinder", action: makePreview)
                    .disabled(job != nil || isStale || (try? available?.get()) == nil)
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
