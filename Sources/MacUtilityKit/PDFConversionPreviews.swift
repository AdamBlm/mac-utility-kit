import AppKit
import ImageIO
import SwiftUI
import UtilityCore

struct PDFRasterExportPreview: View {
    let input: URL
    let options: PDFToImagesOptions
    @Binding var valid: Bool
    @State private var plans: [PDFPageRasterPlan] = []
    @State private var error: String?
    @State private var selectedPage: Int?
    @State private var plannedKey: RenderKey?

    private struct RenderKey: Hashable {
        let input: URL
        let options: PDFToImagesOptions
    }

    private var renderKey: RenderKey { RenderKey(input: input, options: options) }

    var body: some View {
        Group {
            if plannedKey != renderKey {
                ProgressView("Planning image export…").controlSize(.small)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if !plans.isEmpty {
                DisclosureGroup("\(plans.count) images to export") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
                                HStack {
                                    Text(plan.filename).lineLimit(1).help(plan.filename)
                                    Spacer()
                                    Text("\(plan.width) × \(plan.height)")
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 160)
                }
                DisclosureGroup("Render preview") {
                    let page = plans.first(where: { $0.pageNumber == selectedPage }) ?? plans[0]
                    if plans.count > 1 {
                        SettingRow("Preview page") {
                            Picker("Preview page", selection: Binding(
                                get: { page.pageNumber },
                                set: { selectedPage = $0 }
                            )) {
                                ForEach(plans) { plan in
                                    Text("Page \(plan.pageNumber)").tag(plan.pageNumber)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    PDFRasterThumbnail(input: input, pageNumber: page.pageNumber, options: options)
                        .id(page.pageNumber)
                        .id(renderKey)
                        .padding(.top, 6)
                }
            }
        }
        .onChange(of: input) { selectedPage = nil }
        .task(id: renderKey) { [request = renderKey] in
            plans = []
            error = nil
            valid = false
            do {
                let planned = try await Task.detached(priority: .utility) {
                    try PDFToImages.plans(request.input, options: request.options)
                }.value
                if !Task.isCancelled {
                    plans = planned
                    plannedKey = request
                    valid = !planned.isEmpty
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    plannedKey = request
                }
            }
        }
    }
}

struct ImagePDFPagePreview: View {
    let input: URL
    let pageNumber: Int
    let options: ImagesToPDFOptions
    let background: Color
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let layout = try? ImagesToPDF.layout(input, options: options) {
                pagePreview(layout)
                Text("\(Double(layout.page.width).formatted(.number.precision(.fractionLength(0)))) × \(Double(layout.page.height).formatted(.number.precision(.fractionLength(0)))) pt")
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                if options.placement == .fill,
                   layout.image.width > layout.printableArea.width + 0.01
                    || layout.image.height > layout.printableArea.height + 0.01 {
                    Text("Fill crops this image at the printable edges.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Preview unavailable. Check the image and page settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: input) {
            let preview = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 520
                ] as CFDictionary)
            }.value
            if !Task.isCancelled { thumbnail = preview }
        }
    }

    private func pagePreview(_ layout: PDFImageLayout) -> some View {
        let scale = min(240 / layout.page.width, 175 / layout.page.height)
        let box = layout.printableArea
        return ZStack(alignment: .topLeading) {
            background
            ZStack(alignment: .topLeading) {
                Color.clear
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .frame(width: layout.image.width * scale, height: layout.image.height * scale)
                        .position(x: (layout.image.midX - box.minX) * scale,
                                  y: (box.maxY - layout.image.midY) * scale)
                }
            }
            .frame(width: box.width * scale, height: box.height * scale)
            .clipped()
            .position(x: (box.midX - layout.page.minX) * scale,
                      y: (layout.page.maxY - box.midY) * scale)
        }
        .frame(width: layout.page.width * scale, height: layout.page.height * scale)
        .overlay { Rectangle().strokeBorder(.secondary.opacity(0.35)) }
        .accessibilityLabel("Page \(pageNumber) with selected paper and placement")
    }
}


private struct PDFRasterThumbnail: View {
    let input: URL
    let pageNumber: Int
    let options: PDFToImagesOptions
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 200)
                    .background(.quaternary.opacity(0.45))
                    .overlay { Rectangle().strokeBorder(.secondary.opacity(0.25)) }
                    .accessibilityLabel("Rendered page \(pageNumber)")
                Text(options.transparent ? "Scaled preview. Shaded areas will be transparent." : "Scaled preview.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if failed {
                Text("Could not render this preview.").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            do {
                let preview = try await PDFToImages.preview(input, pageNumber: pageNumber, options: options)
                guard !Task.isCancelled else { return }
                image = preview
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
