import SwiftUI
import UtilityCore

struct VideoResizeControls: View {
    let inputs: [URL]
    @Binding var options: VideoResizeOptions
    @State private var sources: SourceReview?
    @State private var previewFile: URL?
    @State private var rendered: Rendered?

    private struct Source {
        let size: CGSize?
        let error: String?
    }

    private struct SourceReview {
        let inputs: [URL]
        var details: [URL: Source] = [:]
    }

    private struct SourceRequest: Equatable {
        let inputs: [URL]
        let priority: URL?
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

    private var activeFile: URL? {
        if let previewFile, inputs.contains(previewFile) { return previewFile }
        return inputs.first
    }

    var body: some View {
        let active = activeFile
        let request = active.map { PreviewRequest(url: $0, options: options) }
        let sourceRequest = SourceRequest(inputs: inputs, priority: active)
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
            if inputs.count > 1 {
                batchDimensions
                SettingRow("Preview file") {
                    Picker("Preview file", selection: Binding(get: { activeFile }, set: { previewFile = $0 })) {
                        ForEach(Array(inputs.enumerated()), id: \.offset) { index, file in
                            Text("\(index + 1). \(file.lastPathComponent)").tag(Optional(file))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let request {
                if let source = source(for: request.url), let size = source.size {
                    sourceDetails(size, request: request)
                } else if let error = source(for: request.url)?.error {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                } else {
                    ProgressView("Reading video dimensions…").controlSize(.small)
                }
            }
        }
        .task(id: sourceRequest) { await loadSources(sourceRequest) }
        .task(id: request) { await render(request) }
    }

    private var batchDimensions: some View {
        DisclosureGroup("Batch output dimensions") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { index, file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(file.lastPathComponent)").lineLimit(1).help(file.path)
                            if let source = source(for: file), let size = source.size {
                                switch Result(catching: { try VideoResizeLayout.plan(sourceSize: size, options: options) }) {
                                case .success(let layout):
                                    let before = "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px"
                                    Text("\(before) → \(layout.width) × \(layout.height) px").monospacedDigit()
                                case .failure(let error):
                                    Text(error.localizedDescription)
                                }
                            } else {
                                Text(source(for: file)?.error ?? "Reading dimensions…")
                            }
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 205)
        }
    }

    @ViewBuilder
    private func sourceDetails(_ size: CGSize, request: PreviewRequest) -> some View {
        let layout = Result { try VideoResizeLayout.plan(sourceSize: size, options: options) }
        switch layout {
        case .success(let layout):
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

    private func source(for file: URL) -> Source? {
        guard sources?.inputs == inputs else { return nil }
        return sources?.details[file]
    }

    private func loadSources(_ request: SourceRequest) async {
        guard !Task.isCancelled else { return }
        if sources?.inputs != request.inputs { sources = SourceReview(inputs: request.inputs) }
        let ordered = request.priority.map { [$0] } ?? []
        let files = ordered + request.inputs.filter { $0 != request.priority }
        for file in files where sources?.details[file] == nil {
            let result: Source
            do {
                let size = try await VideoResize.sourceSize(file)
                result = Source(size: size, error: nil)
            } catch {
                result = Source(size: nil, error: error.localizedDescription)
            }
            guard !Task.isCancelled, sources?.inputs == request.inputs else { return }
            sources?.details[file] = result
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
