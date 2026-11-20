import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct TextExtractionSettings: View {
    let inputs: [URL]
    @Binding var options: TextExtractionOptions
    @State private var languages: [String] = []
    @State private var showRegion = false
    @State private var selectedRegionSource: URL?

    private var regionSources: [URL] {
        var seen: Set<URL> = []
        return inputs.filter { seen.insert($0).inserted }
    }

    private var regionSource: URL? {
        if let selectedRegionSource, inputs.contains(selectedRegionSource) { return selectedRegionSource }
        return inputs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Language") {
                Picker("Recognition language", selection: $options.language) {
                    Text("Automatic").tag(String?.none)
                    ForEach(languages, id: \.self) { language in
                        Text(Locale.current.localizedString(forIdentifier: language) ?? language)
                            .tag(Optional(language))
                    }
                }
                .labelsHidden()
            }
            let hasPDF = inputs.contains(where: isPDF)
            let hasTIFF = inputs.contains { isContentType($0, .tiff) }
            if hasPDF || hasTIFF {
                SettingRow("Pages") {
                    TextField("All, or e.g. 1, 3–5", text: $options.range).accessibilityLabel("PDF or TIFF page range")
                }
                Toggle("Include page breaks in text files", isOn: $options.includePageBreaks)
            }
            if hasPDF {
                DisclosureGroup("PDF options") {
                    Toggle("Use embedded text when available", isOn: $options.preferEmbeddedText)
                    if !options.preferEmbeddedText {
                        Text("Runs OCR across each selected PDF page, including images on pages with embedded text.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("PDF password", text: $options.password)
                        .padding(.top, 6)
                }
            }
            Toggle("Recognize only a region", isOn: Binding(
                get: { options.region != nil },
                set: { enabled in
                    options.region = enabled ? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) : nil
                    showRegion = enabled
                }
            ))
            if options.region != nil, let input = regionSource {
                DisclosureGroup("Region preview", isExpanded: $showRegion) {
                    VStack(alignment: .leading, spacing: 8) {
                        let sources = regionSources
                        if sources.count > 1 {
                            SettingRow("Preview source") {
                                Picker("Region preview source", selection: Binding(
                                    get: { regionSource }, set: { selectedRegionSource = $0 }
                                )) {
                                    ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                                        Text("\(index + 1). \(source.lastPathComponent)").tag(Optional(source))
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                        OCRRegionPagePreview(input: input, range: options.range, password: options.password,
                                             region: $options.region)
                        HStack(spacing: 8) {
                            regionField("Left %", \.origin.x, origin: true, horizontal: true)
                            regionField("Top %", \.origin.y, origin: true, horizontal: false)
                            regionField("Width %", \.size.width, origin: false, horizontal: true)
                            regionField("Height %", \.size.height, origin: false, horizontal: false)
                        }
                        Text("Drag to select a region. The same proportion of each selected page or file is used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .task {
            languages = ((try? TextExtraction.languages()) ?? []).sorted {
                let left = Locale.current.localizedString(forIdentifier: $0) ?? $0
                let right = Locale.current.localizedString(forIdentifier: $1) ?? $1
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        }
    }

    private func regionField(
        _ title: String, _ path: WritableKeyPath<CGRect, CGFloat>, origin: Bool, horizontal: Bool
    ) -> some View {
        let value = Binding<Int>(
            get: { Int(((options.region?[keyPath: path] ?? 0) * 100).rounded()) },
            set: { percent in
                guard var region = options.region else { return }
                let limit = horizontal ? region.maxX : region.maxY
                let offset = horizontal ? region.minX : region.minY
                let remaining = origin ? 1 - (limit - offset) : 1 - offset
                let minimum: CGFloat = origin ? 0 : 0.01
                region[keyPath: path] = min(remaining, max(minimum, CGFloat(percent) / CGFloat(100)))
                options.region = region
            }
        )
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.grouping(.never))
                .accessibilityLabel(title)
        }
    }
}

struct TextExtractionResultView: View {
    let file: ExtractedTextFile
    let password: String
    @State private var selectedPage: Int?
    @State var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if file.result.pages.count > 1 {
                    Picker("Page", selection: $selectedPage) {
                        ForEach(file.result.pages) { page in
                            Text(page.pageNumber.map { "Page \($0)" } ?? "Image").tag(Optional(page.id))
                        }
                    }
                }
                if let page = file.result.pages.first(where: { $0.id == selectedPage }) ?? file.result.pages.first {
                    HStack(alignment: .top, spacing: 12) {
                        OCRSourcePreview(input: file.source, pageNumber: page.pageNumber, pageRange: "", password: password, region: .constant(nil))
                            .frame(minWidth: 130, idealWidth: 225, maxWidth: 250, minHeight: 185)
                        ScrollView {
                            Text(page.error ?? (page.text.isEmpty ? "No text recognized." : page.text))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minWidth: 150, maxHeight: 220)
                    }
                }
            }
            .padding(.top, 8)
            .onAppear {
                if selectedPage == nil { selectedPage = file.result.pages.first?.id }
            }
        } label: {
            HStack {
                Text(file.source.lastPathComponent).lineLimit(1)
                Spacer(minLength: 8)
                Button("Copy text", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.result.text, forType: .string)
                }
                .disabled(file.result.text.isEmpty)
            }
        }
        .font(.callout)
    }
}

private struct OCRRegionPagePreview: View {
    let input: URL
    let range: String
    let password: String
    @Binding var region: CGRect?
    @State private var selected: Int?
    @State private var listing: (request: Request, result: Result<[Int], any Error>)?

    private struct Request: Equatable {
        let input: URL
        let range: String
        let password: String
    }

    var body: some View {
        let request = Request(input: input, range: range, password: password)
        Group {
            if let listing, listing.request == request {
                switch listing.result {
                case .success(let pages):
                    let page = selected.flatMap { pages.contains($0) ? $0 : nil } ?? pages.first
                    if pages.count > 1, let page {
                        SettingRow("Preview page") {
                            Picker("Region preview page", selection: Binding(get: { page }, set: { selected = $0 })) {
                                ForEach(pages, id: \.self) { number in Text("Page \(number)").tag(number) }
                            }
                            .labelsHidden()
                        }
                    }
                    preview(page: page)
                case .failure(let error):
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Reading preview pages…").controlSize(.small)
            }
        }
        .task(id: request) {
            do {
                let pages = try await TextExtraction.regionPreviewPages(input, range: range, password: password)
                try Task.checkCancellation()
                if listing?.request.input != request.input { selected = nil }
                listing = (request, .success(pages))
            } catch {
                guard !Task.isCancelled else { return }
                listing = (request, .failure(error))
            }
        }
    }

    private func preview(page: Int?) -> some View {
        OCRSourcePreview(input: input, pageNumber: page, pageRange: range, password: password, region: $region)
            .frame(height: 205)
    }
}

private struct OCRSourcePreview: View {
    let input: URL
    let pageNumber: Int?
    let pageRange: String
    let password: String
    @Binding var region: CGRect?
    @Environment(\.colorScheme) private var colorScheme
    @State private var preview: Preview?
    @State private var dragRegion: CGRect?

    private struct SourceKey: Hashable {
        let input: URL
        let pageNumber: Int?
        let pageRange: String
        let password: String
    }

    private struct Preview {
        let source: SourceKey
        let thumbnail: NSImage?
    }

    var body: some View {
        let key = SourceKey(input: input, pageNumber: pageNumber, pageRange: pageRange, password: password)
        GeometryReader { geometry in
            if let preview, preview.source == key, let thumbnail = preview.thumbnail,
               thumbnail.size.width > 0, thumbnail.size.height > 0 {
                let scale = min(geometry.size.width / thumbnail.size.width, geometry.size.height / thumbnail.size.height)
                let width = thumbnail.size.width * scale
                let height = thumbnail.size.height * scale
                Image(nsImage: thumbnail)
                    .resizable()
                    .frame(width: width, height: height)
                    .overlay {
                        if let box = dragRegion ?? region {
                            let accent = WorkspacePalette(dark: colorScheme == .dark).accent
                            Rectangle()
                                .fill(accent.opacity(0.16))
                                .overlay { Rectangle().strokeBorder(accent, lineWidth: 2) }
                                .frame(width: box.width * width, height: box.height * height)
                                .position(x: box.midX * width, y: box.midY * height)
                                .allowsHitTesting(false)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            if self.preview?.source == key, region != nil {
                                dragRegion = selection(value, width: width, height: height)
                            }
                        }
                        .onEnded { value in
                            guard self.preview?.source == key else { return }
                            if region != nil, let chosen = selection(value, width: width, height: height) {
                                region = chosen
                            }
                            dragRegion = nil
                        }, including: region == nil ? .none : .gesture)
                    .id(key)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if preview?.source == key {
                Text("Preview unavailable")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("Source preview")
        .task(id: key) {
            guard !Task.isCancelled else { return }
            preview = nil
            dragRegion = nil
            if isPDF(input) {
                guard let document = PDFDocument(url: input),
                      !document.isLocked || document.unlock(withPassword: password) else {
                    preview = Preview(source: key, thumbnail: nil)
                    return
                }
                let index = try? TextExtraction.previewPageIndex(pageNumber: pageNumber, pageRange: pageRange,
                                                                  pageCount: document.pageCount)
                let thumbnail = index.flatMap { document.page(at: $0) }?
                    .thumbnail(of: NSSize(width: 450, height: 450), for: .cropBox)
                preview = Preview(source: key, thumbnail: thumbnail)
            } else {
                let image = await Task.detached(priority: .utility) {
                    try? TextExtraction.imagePreview(input, pageNumber: pageNumber, pageRange: pageRange)
                }.value
                if !Task.isCancelled {
                    preview = Preview(source: key, thumbnail: image.map { NSImage(cgImage: $0, size: .zero) })
                }
            }
        }
    }

    private func selection(_ value: DragGesture.Value, width: CGFloat, height: CGFloat) -> CGRect? {
        func unit(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
        let x1 = unit(value.startLocation.x / width)
        let y1 = unit(value.startLocation.y / height)
        let x2 = unit(value.location.x / width)
        let y2 = unit(value.location.y / height)
        let region = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        return region.width >= 0.01 && region.height >= 0.01 ? region : nil
    }
}

private func isPDF(_ url: URL) -> Bool {
    isContentType(url, .pdf)
}

private func isContentType(_ url: URL, _ type: UTType) -> Bool {
    (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: type)) == true
}
