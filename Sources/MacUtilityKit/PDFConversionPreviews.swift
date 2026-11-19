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

    private var renderKey: String {
        [
            input.path, options.range, options.format.rawValue, options.resolution.rawValue,
            String(options.dpi), String(options.maxWidth), String(options.maxHeight),
            options.filenamePattern, String(options.transparent), String(options.quality)
        ].joined(separator: "\u{0}")
    }

    var body: some View {
        Group {
            if let error {
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
                DisclosureGroup("First-page render preview") {
                    PDFRasterThumbnail(input: input, pageNumber: plans[0].pageNumber, options: options)
                        .id(renderKey)
                        .padding(.top, 6)
                }
            }
        }
        .task(id: renderKey) {
            plans = []
            error = nil
            valid = false
            do {
                let planned = try await Task.detached(priority: .utility) {
                    try PDFToImages.plans(input, options: options)
                }.value
                if !Task.isCancelled {
                    plans = planned
                    valid = !planned.isEmpty
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
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
                let preview = try await render()
                guard !Task.isCancelled else { return }
                image = preview
                failed = preview == nil
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    private nonisolated func render() async throws -> CGImage? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacUtilityKit-PagePreview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var preview = options
        preview.range = String(pageNumber)
        preview.format = .png
        preview.resolution = .bounds
        preview.maxWidth = 420
        preview.maxHeight = 420
        preview.filenamePattern = "Preview-{page}"
        let output = try await PDFToImages.export(input, into: folder, options: preview) { _ in }
        guard let url = output.first, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
