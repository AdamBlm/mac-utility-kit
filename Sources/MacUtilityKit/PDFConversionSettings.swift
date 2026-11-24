import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UtilityCore

struct PDFExtractSettings: View {
    let document: PDFDocument
    @Binding var options: PDFExtractOptions
    @State private var showsOrder = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Page order") {
                Picker("Page order", selection: $options.order) {
                    ForEach(PDFExtractOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            PDFExportPagePicker(document: document, range: $options.range, startsWithAll: false,
                                allowsDescendingRanges: true)
            if options.order == .selection {
                Text("Enter a range like 8–3 to export those pages in reverse order.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let pages = try? PDFPageEditing.extractPages(pageCount: document.pageCount, options: options) {
                DisclosureGroup("Export order · \(pages.count) \(pages.count == 1 ? "page" : "pages")", isExpanded: $showsOrder) {
                    ScrollView {
                        Text(PageSelection.expression(for: pages.map { $0 - 1 }))
                            .font(.callout.monospacedDigit())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }
}

struct PDFToImagesSettings: View {
    let input: URL
    let document: PDFDocument
    @Binding var options: PDFToImagesOptions
    @Binding var valid: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PDFExportPagePicker(document: document, range: $options.range, startsWithAll: true)
            Divider()
            SettingRow("File format") {
                Picker("File format", selection: Binding(
                    get: { options.format },
                    set: { format in
                        options.format = format
                        if format != .png { options.transparent = false }
                    }
                )) {
                    Text("PNG").tag(PDFPageImageFormat.png)
                    Text("JPEG").tag(PDFPageImageFormat.jpg)
                    Text("HEIC").tag(PDFPageImageFormat.heic)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            SettingRow("Resolution") {
                Picker("Resolution", selection: $options.resolution) {
                    Text("DPI").tag(PDFImageResolution.dpi)
                    Text("Pixel bounds").tag(PDFImageResolution.bounds)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if options.resolution == .dpi {
                SettingRow("DPI") {
                    TextField("Dots per inch", value: $options.dpi, format: .number.grouping(.never))
                }
            } else {
                SettingRow("Pixel bounds") {
                    HStack {
                        TextField("Maximum width", value: $options.maxWidth, format: .number.grouping(.never))
                            .accessibilityLabel("Maximum pixel width")
                        Text("×").foregroundStyle(.secondary)
                        TextField("Maximum height", value: $options.maxHeight, format: .number.grouping(.never))
                            .accessibilityLabel("Maximum pixel height")
                    }
                }
            }
            if options.format == .png {
                Toggle("Keep transparent page background", isOn: $options.transparent)
            } else {
                SettingRow("Quality") {
                    HStack {
                        Slider(value: $options.quality, in: 0.05...1) { Text("Quality") }.labelsHidden()
                        Text(options.quality.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            SettingRow("Filename pattern") {
                TextField("Filename pattern", text: $options.filenamePattern)
                    .help("Use {name}, {page}, or {number}")
            }
            Text("Use {name} for the document name, {page} for the source page, or {number} for the export sequence.")
                .font(.caption).foregroundStyle(.secondary)
            PDFRasterExportPreview(input: input, options: options, valid: $valid)
        }
    }
}

struct PDFExportPagePicker: View {
    let document: PDFDocument
    @Binding var range: String
    let startsWithAll: Bool
    var anchorResetID: UUID? = nil
    var allowsDescendingRanges = false
    @State private var expanded = false
    @State private var anchor: Int?

    var body: some View {
        let selection = Result { try pageIndices() }
        let selected = try? selection.get()
        VStack(alignment: .leading, spacing: 8) {
            SettingRow("Pages") {
                TextField(startsWithAll ? "All, or e.g. 1, 4–6" : "Enter pages, e.g. 1, 4–6", text: Binding(
                    get: { range },
                    set: { value in
                        range = value
                        anchor = nil
                    }
                ))
                .accessibilityLabel("Page range")
            }
            HStack(spacing: 8) {
                Group {
                    switch selection {
                    case .success(let pages):
                        Text("\(pages.count) of \(document.pageCount) pages selected")
                    case .failure(let error):
                        Text(error.localizedDescription)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Select all") { range = "all"; anchor = nil }
                Button("Clear") { range = "none"; anchor = nil }
            }
            DisclosureGroup("Page thumbnails", isExpanded: $expanded) {
                if expanded {
                    thumbnailStrip(selected: selected ?? [])
                }
            }
        }
        .onChange(of: ObjectIdentifier(document)) { anchor = nil }
        .onChange(of: anchorResetID) { anchor = nil }
    }

    private func pageIndices() throws -> [Int] {
        if !startsWithAll, range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return try PageSelection.indices(range, pageCount: document.pageCount,
                                         allowsDescendingRanges: allowsDescendingRanges)
    }

    private func thumbnailStrip(selected: [Int]) -> some View {
        let marked = Set(selected)
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(0..<document.pageCount, id: \.self) { index in
                    Button {
                        let start = NSEvent.modifierFlags.contains(.shift) ? anchor : nil
                        let edits = PageSelection.updating(selected, at: index, extendingFrom: start,
                                                          keepsRangeDirection: allowsDescendingRanges)
                        anchor = index
                        range = PageSelection.expression(for: edits)
                    } label: {
                        VStack(spacing: 5) {
                            PDFPageThumbnail(page: document.page(at: index))
                            Label("Page \(index + 1)", systemImage: marked.contains(index) ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(PDFPageCardStyle(selected: marked.contains(index)))
                    .accessibilityAddTraits(marked.contains(index) ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ImagesToPDFSettings: View {
    let inputs: [URL]
    @Binding var options: ImagesToPDFOptions
    @State private var previewPage = 0

    var body: some View {
        let page = min(previewPage, max(0, inputs.count - 1))
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Paper") {
                Picker("Paper", selection: Binding(
                    get: { options.paper },
                    set: { paper in
                        options.paper = paper
                        if paper == .original {
                            options.orientation = .automatic
                            options.placement = .fit
                        }
                    }
                )) {
                    Text("Original size").tag(PDFImagePaper.original)
                    Text("A4").tag(PDFImagePaper.a4)
                    Text("US Letter").tag(PDFImagePaper.letter)
                    Text("Custom").tag(PDFImagePaper.custom)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if options.paper == .custom {
                SettingRow("Paper size (pt)") {
                    HStack {
                        TextField("Page width", value: $options.width, format: .number)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Page height", value: $options.height, format: .number)
                    }
                }
            }
            if options.paper != .original {
                SettingRow("Orientation") {
                    Picker("Orientation", selection: $options.orientation) {
                        Text("Automatic").tag(PDFImageOrientation.automatic)
                        Text("Portrait").tag(PDFImageOrientation.portrait)
                        Text("Landscape").tag(PDFImageOrientation.landscape)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                SettingRow("Placement") {
                    Picker("Placement", selection: $options.placement) {
                        Text("Fit").tag(PDFImagePlacement.fit)
                        Text("Fill").tag(PDFImagePlacement.fill)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            SettingRow("Margin (pt)") {
                TextField("Page margin in points", value: $options.margin, format: .number)
            }
            SettingRow("Background") {
                ColorPicker("Page background", selection: background, supportsOpacity: false)
                    .labelsHidden()
            }
            if inputs.indices.contains(page) {
                DisclosureGroup("Page preview") {
                    if inputs.count > 1 {
                        Picker("Preview page", selection: Binding(get: { page }, set: { previewPage = $0 })) {
                            ForEach(inputs.indices, id: \.self) { index in
                                Text("\(index + 1). \(inputs[index].lastPathComponent)").tag(index)
                            }
                        }
                    }
                    ImagePDFPagePreview(input: inputs[page], pageNumber: page + 1,
                                        options: options, background: background.wrappedValue)
                        .id(inputs[page])
                        .padding(.top, 6)
                }
            }
        }
        .onChange(of: inputs.count) {
            previewPage = min(previewPage, max(0, inputs.count - 1))
        }
    }

    private var background: Binding<Color> {
        Binding {
            let rgb = options.backgroundRGB
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        } set: { color in
            guard let value = NSColor(color).usingColorSpace(.sRGB) else { return }
            options.backgroundRGB = [value.redComponent, value.greenComponent, value.blueComponent]
                .reduce(UInt32(0)) { ($0 << 8) | UInt32((min(1, max(0, $1)) * 255).rounded()) }
        }
    }
}
