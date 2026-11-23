import SwiftUI
import UtilityCore

struct ImageComparisonView: View {
    let pair: ImageComparisonResult
    var summary: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var magnification: Double = 0
    @State private var x = 0.5
    @State private var y = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(pair.inputLabel)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(pair.source.path)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 14) {
                comparisonPane("Original", url: pair.source, bytes: pair.sourceBytes, expected: pair.sourceVersion)
                comparisonPane("Compressed", url: pair.output, bytes: pair.outputBytes)
            }
            if let summary {
                Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Picker("Zoom", selection: $magnification) {
                Text("Fit").tag(0.0)
                Text("100%").tag(1.0)
                Text("200%").tag(2.0)
                Text("400%").tag(4.0)
            }
            .pickerStyle(.segmented)
            if magnification > 0 {
                Slider(value: $x, in: 0...1) { Text("Horizontal position") }
                Slider(value: $y, in: 0...1) { Text("Vertical position") }
            }
        }
        .padding(22)
        .frame(minWidth: 640, minHeight: 420)
    }

    private func comparisonPane(
        _ title: String, url: URL, bytes: Int?, expected: LocalInputFile.Version? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                if let bytes {
                    Text(Int64(bytes), format: .byteCount(style: .file))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ImageComparisonPane(url: url, expected: expected, magnification: magnification, center: CGPoint(x: x, y: y))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImageComparisonPane: View {
    let url: URL
    let expected: LocalInputFile.Version?
    let magnification: Double
    let center: CGPoint
    @Environment(\.displayScale) private var displayScale
    @State private var preview: ImageComparisonPreview?
    @State private var failed = false

    private struct Request: Equatable {
        let url: URL
        let detail: Bool
        let expected: LocalInputFile.Version?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                Group {
                    if let preview {
                        if magnification == 0 {
                            Image(decorative: preview.image, scale: 1)
                                .resizable().scaledToFit()
                        } else {
                            let scale = displayScale / (magnification * preview.pixelsPerSample)
                            let viewport = CGSize(width: geometry.size.width * scale, height: geometry.size.height * scale)
                            if let tile = preview.region(center: center, viewport: viewport) {
                                Image(decorative: tile, scale: 1)
                                    .resizable().interpolation(.none)
                                    .frame(width: CGFloat(tile.width) / scale, height: CGFloat(tile.height) / scale)
                            }
                        }
                    } else if failed {
                        ContentUnavailableView("Preview unavailable", systemImage: "photo")
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if let preview, !preview.isFullResolution, magnification > 0 {
                    Text("Reduced preview")
                        .font(.caption)
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
        }
        .task(id: Request(url: url, detail: magnification > 0, expected: expected)) {
            let detail = magnification > 0
            preview = nil
            failed = false
            let worker = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as ImageComparisonPreview? }
                return ImageComparisonPreview.load(url, detail: detail, expected: expected)
            }
            let loaded = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            preview = loaded
            failed = loaded == nil
        }
        .accessibilityLabel(url.lastPathComponent)
    }
}
