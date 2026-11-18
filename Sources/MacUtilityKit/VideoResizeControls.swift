import SwiftUI
import UtilityCore

struct VideoResizeControls: View {
    let inputs: [URL]
    @Binding var options: VideoResizeOptions
    @State private var source: Source?
    @State private var rendered: Rendered?

    private struct Source {
        let url: URL
        let size: CGSize?
        let error: String?
    }

    private struct PreviewRequest: Equatable {
        let url: URL
        let options: VideoResizeOptions
    }

    private struct Rendered {
        let request: PreviewRequest
        let image: CGImage?
        let error: String?
    }

    var body: some View {
        let url = inputs.first
        let request = url.map { PreviewRequest(url: $0, options: options) }
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Size by") {
                Picker("Size by", selection: $options.sizing) {
                    ForEach(VideoResizeSizing.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            switch options.sizing {
            case .preset:
                SettingRow("Resolution") {
                    Picker("Resolution", selection: $options.preset) {
                        ForEach(VideoResizePreset.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            case .dimensions:
                SettingRow("Width") {
                    PixelInput(label: "Width in pixels", value: $options.width)
                    Text("px").foregroundStyle(.secondary)
                }
                Toggle("Lock source aspect ratio", isOn: $options.locksAspectRatio)
                if !options.locksAspectRatio {
                    SettingRow("Height") {
                        PixelInput(label: "Height in pixels", value: $options.height)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
            case .percentage:
                SettingRow("Scale") {
                    PixelInput(label: "Scale percentage", value: $options.percentage)
                    Text("%").foregroundStyle(.secondary)
                }
            }
            if options.sizing == .preset || (options.sizing == .dimensions && !options.locksAspectRatio) {
                SettingRow("Framing") {
                    Picker("Framing", selection: $options.framing) {
                        ForEach(VideoResizeFraming.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            if source?.url == url {
                if let size = source?.size {
                    sourceDetails(size, request: request)
                } else if let error = source?.error {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) { await loadSource(url) }
        .task(id: request) { await render(request) }
    }

    @ViewBuilder
    private func sourceDetails(_ size: CGSize, request: PreviewRequest?) -> some View {
        let layout = Result { try VideoResizeLayout.plan(sourceSize: size, options: options) }
        switch layout {
        case .success(let layout):
            if inputs.count > 1, let request {
                Text(request.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .font(.callout).foregroundStyle(.secondary)
            }
            LabeledContent("Source", value: "\(Double(size.width).formatted(.number.precision(.fractionLength(0)))) × \(Double(size.height).formatted(.number.precision(.fractionLength(0)))) px")
                .font(.callout.monospacedDigit())
                .frame(maxWidth: 310)
            LabeledContent("Output", value: "\(layout.width) × \(layout.height) px")
                .font(.callout.monospacedDigit())
                .frame(maxWidth: 310)
            if rendered?.request == request {
                if let image = rendered?.image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 210)
                        .accessibilityLabel("Output framing preview")
                } else if let error = rendered?.error {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
            }
        case .failure(let error):
            Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func loadSource(_ url: URL?) async {
        guard let url else { source = nil; return }
        do {
            let size = try await VideoResize.sourceSize(url)
            if !Task.isCancelled { source = Source(url: url, size: size, error: nil) }
        } catch {
            if !Task.isCancelled { source = Source(url: url, size: nil, error: error.localizedDescription) }
        }
    }

    private func render(_ request: PreviewRequest?) async {
        guard let request else { rendered = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(150))
            let image = try await VideoResize.preview(request.url, options: request.options)
            if !Task.isCancelled { rendered = Rendered(request: request, image: image, error: nil) }
        } catch {
            if !Task.isCancelled { rendered = Rendered(request: request, image: nil, error: error.localizedDescription) }
        }
    }
}

private struct PixelInput: View {
    let label: String
    @Binding var value: Int
    @State private var typed: String?

    var body: some View {
        TextField(label, text: Binding {
            typed ?? (value == 0 ? "" : String(value))
        } set: { text in
            typed = text
            value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        })
        .frame(width: 90)
    }
}
