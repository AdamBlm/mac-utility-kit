import ImageIO
import SwiftUI
import UtilityCore

struct ImageComparisonView: View {
    let pair: ImageComparisonResult

    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Compare images").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 14) {
                comparisonPane("Original", url: pair.source)
                comparisonPane("Compressed", url: pair.output)
            }
            HStack {
                Slider(value: $zoom, in: 1...4) { Text("Preview zoom") }
                Text(zoom.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(minWidth: 640, minHeight: 420)
    }

    private func comparisonPane(_ title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.semibold))
            ImageComparisonPane(url: url, zoom: zoom)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImageComparisonPane: View {
    let url: URL
    let zoom: Double
    @State private var thumbnail: CGImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            if let thumbnail {
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                }
            } else if failed {
                ContentUnavailableView("Preview unavailable", systemImage: "photo")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            let image = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_600
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = image
            failed = image == nil
        }
        .accessibilityLabel(url.lastPathComponent)
    }
}
