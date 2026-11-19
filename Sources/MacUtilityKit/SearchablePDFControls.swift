import PDFKit
import SwiftUI
import UtilityCore

struct SearchablePDFControls: View {
    let inputs: [URL]
    @Binding var options: SearchablePDFOptions
    @State private var languages: [String] = []
    @State private var sourceDocument: LoadedPDF?
    @State private var page: Int?
    @State private var selectedSource: URL?
    @State private var rendered: Preview?
    @State private var previewTask: Task<Void, Never>?

    private struct LoadedPDF {
        let input: URL
        let result: Result<PDFDocument, any Error>
    }

    private struct PreviewRequest: Equatable {
        let input: URL
        let page: Int
        let options: SearchablePDFOptions
    }

    private struct Preview {
        let request: PreviewRequest
        let result: Result<SearchablePDFPreview, any Error>
    }

    private var previewSources: [URL] {
        var seen: Set<URL> = []
        return inputs.filter { seen.insert($0).inserted }
    }

    private var previewSource: URL? {
        if let selectedSource, inputs.contains(selectedSource) { return selectedSource }
        return inputs.first
    }

    var body: some View {
        let input = previewSource
        let current = sourceDocument?.input == input ? sourceDocument?.result : nil
        let document = try? current?.get()
        let selected = document.flatMap { try? PageSelection.indices(options.range, pageCount: $0.pageCount) }
        let pages = selected?.map { $0 + 1 } ?? []
        let preview = input.flatMap { input in
            (page.flatMap { pages.contains($0) ? $0 : nil } ?? pages.first).map {
                PreviewRequest(input: input, page: $0, options: options)
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Language") {
                Picker("Recognition language", selection: $options.language) {
                    Text("Automatic").tag(String?.none)
                    ForEach(languages, id: \.self) { language in
                        Text(Locale.current.localizedString(forIdentifier: language) ?? language).tag(Optional(language))
                    }
                }
                .labelsHidden()
            }
            Toggle("Skip pages that already contain searchable text", isOn: $options.skipsSearchablePages)
            let sources = previewSources
            if sources.count > 1 {
                SettingRow("Preview source") {
                    Picker("Preview source", selection: Binding(get: { previewSource }, set: { selectedSource = $0 })) {
                        ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                            Text("\(index + 1). \(source.lastPathComponent)").tag(Optional(source))
                        }
                    }
                    .labelsHidden()
                }
                Text("The page range applies to all PDFs in the batch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let document {
                PDFExportPagePicker(document: document, range: $options.range, startsWithAll: true)
                if let preview {
                    previewControls(pages, request: preview)
                } else if selected?.isEmpty == true {
                    Text("Select at least one page.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                SettingRow("Pages") {
                    TextField("All, or e.g. 1, 3–5", text: $options.range)
                        .accessibilityLabel("PDF page range")
                }
                if case .failure(let error) = current {
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                } else if input != nil {
                    ProgressView("Reading preview pages…").controlSize(.small)
                }
            }
        }
        .task { loadLanguages() }
        .task(id: input) {
            guard let input else { sourceDocument = nil; return }
            page = nil
            do {
                let document = try await Self.loadSource(input)
                guard !Task.isCancelled else { return }
                sourceDocument = LoadedPDF(input: input, result: .success(document))
            } catch {
                guard !Task.isCancelled else { return }
                sourceDocument = LoadedPDF(input: input, result: .failure(error))
            }
        }
        .onChange(of: preview) { clearPreview() }
        .onDisappear { clearPreview() }
    }

    @concurrent
    private static func loadSource(_ input: URL) async throws -> sending PDFDocument {
        try Task.checkCancellation()
        let document = try SearchablePDF.open(input)
        try Task.checkCancellation()
        return document
    }

    private func previewControls(_ pages: [Int], request: PreviewRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow("Preview page") {
                Picker("Preview page", selection: Binding(get: { request.page }, set: { page = $0 })) {
                    ForEach(pages, id: \.self) { number in Text("Page \(number)").tag(number) }
                }
                .labelsHidden()
                Button("Preview Text", systemImage: "text.viewfinder") { runPreview(request) }
                    .disabled(previewTask != nil)
            }
            if previewTask != nil {
                HStack {
                    ProgressView("Recognizing text…").controlSize(.small)
                    Button("Cancel") { clearPreview() }
                }
            } else if rendered?.request == request, let result = rendered?.result {
                switch result {
                case .success(let preview):
                    HStack(alignment: .top, spacing: 12) {
                        Image(decorative: preview.image, scale: 1)
                            .resizable().scaledToFit().frame(maxWidth: 210, maxHeight: 240)
                            .accessibilityLabel("Source PDF page \(preview.result.pageNumber)")
                        ScrollView {
                            Text(preview.result.text.isEmpty ? "No text recognized." : preview.result.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 130, maxHeight: 240)
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadLanguages() {
        languages = ((try? TextExtraction.languages()) ?? []).sorted {
            let left = Locale.current.localizedString(forIdentifier: $0) ?? $0
            let right = Locale.current.localizedString(forIdentifier: $1) ?? $1
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private func runPreview(_ request: PreviewRequest) {
        clearPreview()
        previewTask = Task {
            do {
                let result = try await SearchablePDF.preview(request.input, pageNumber: request.page, options: request.options)
                guard !Task.isCancelled else { return }
                rendered = Preview(request: request, result: .success(result))
            } catch {
                guard !Task.isCancelled else { return }
                rendered = Preview(request: request, result: .failure(error))
            }
            previewTask = nil
        }
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        rendered = nil
    }
}
