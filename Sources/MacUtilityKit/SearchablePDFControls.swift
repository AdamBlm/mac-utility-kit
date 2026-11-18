import SwiftUI
import UtilityCore

struct SearchablePDFControls: View {
    let inputs: [URL]
    @Binding var options: SearchablePDFOptions
    @State private var languages: [String] = []
    @State private var selection: PageListing?
    @State private var page: Int?
    @State private var rendered: Preview?
    @State private var previewTask: Task<Void, Never>?

    private struct RangeRequest: Equatable {
        let input: URL
        let range: String
    }

    private struct PageListing {
        let request: RangeRequest
        let result: Result<[Int], any Error>
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

    var body: some View {
        let request = inputs.first.map { RangeRequest(input: $0, range: options.range) }
        let current = selection?.request == request ? selection : nil
        let preview = request.flatMap { query in page.map { PreviewRequest(input: query.input, page: $0, options: options) } }
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
            SettingRow("Pages") {
                TextField("All, or e.g. 1, 3–5", text: $options.range)
                    .accessibilityLabel("PDF page range")
            }
            Toggle("Skip pages that already contain searchable text", isOn: $options.skipsSearchablePages)
            if let current {
                switch current.result {
                case .success(let pages):
                    if !pages.isEmpty, let preview { previewControls(pages, request: preview) }
                    else { Text("Select at least one page.").font(.callout).foregroundStyle(.secondary) }
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task { loadLanguages() }
        .task(id: request) { await listPages(request) }
        .onChange(of: preview) { clearPreview() }
        .onDisappear { clearPreview() }
    }

    private func previewControls(_ pages: [Int], request: PreviewRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if inputs.count > 1 {
                Text(request.input.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingRow("Preview page") {
                Picker("Preview page", selection: $page) {
                    ForEach(pages, id: \.self) { number in Text("Page \(number)").tag(Optional(number)) }
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

    private func listPages(_ request: RangeRequest?) async {
        guard let request else { selection = nil; page = nil; return }
        do {
            var selected = SearchablePDFOptions()
            selected.range = request.range
            let pages = try await SearchablePDF.pageNumbers(request.input, options: selected)
            if !Task.isCancelled {
                selection = PageListing(request: request, result: .success(pages))
                if page == nil || !pages.contains(page ?? 0) { page = pages.first }
            }
        } catch {
            if !Task.isCancelled {
                selection = PageListing(request: request, result: .failure(error))
                page = nil
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
