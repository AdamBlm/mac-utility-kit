import SwiftUI
import UtilityCore

struct VideoCropControls: View {
    let inputs: [URL]
    @Binding var options: VideoCropOptions

    @State private var source: SourcePreview?
    @State private var sourceIssue: String?
    @State private var rendered: RenderedPreview?

    private struct SourcePreview {
        let url: URL
        let size: CGSize
        let image: CGImage
    }

    private struct PreviewInput: Equatable {
        let url: URL?
        let options: VideoCropOptions
    }

    private struct RenderedPreview {
        let input: PreviewInput
        let result: Result<CGImage, any Error>
    }

    var body: some View {
        let request = PreviewInput(url: inputs.first, options: options)
        VStack(alignment: .leading, spacing: 13) {
            SettingRow("Crop ratio") {
                Picker("Crop ratio", selection: Binding(get: { options.aspect }, set: { aspect in
                    options.aspect = aspect
                    options.region = nil
                })) {
                    ForEach(VideoCropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                Button("Reset Crop") { options.region = nil }
                    .disabled(options.region == nil)
            }
            SettingRow("Rotation") {
                Picker("Rotation", selection: $options.rotation) {
                    ForEach(VideoCropRotation.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            HStack(spacing: 16) {
                Toggle("Flip horizontally", isOn: $options.mirrorsHorizontally)
                Toggle("Flip vertically", isOn: $options.mirrorsVertically)
            }
            if let source, source.url == inputs.first {
                cropEditor(source, request: request)
            } else if let sourceIssue {
                Text(sourceIssue).font(.callout).foregroundStyle(.secondary)
            } else if inputs.first != nil {
                ProgressView("Loading frame…").controlSize(.small)
            }
        }
        .task(id: inputs.first) { await loadSource(inputs.first) }
        .task(id: request) { await render(request) }
    }

    @ViewBuilder
    private func cropEditor(_ source: SourcePreview, request: PreviewInput) -> some View {
        let fullFrame = try? VideoCropLayout.plan(sourceSize: source.size, options: resetRegion())
        let layout = Result { try VideoCropLayout.plan(sourceSize: source.size, options: options) }
        if let region = options.region ?? fullFrame?.region {
            HStack(spacing: 10) {
                coordinate("X", \.x, fallback: region)
                coordinate("Y", \.y, fallback: region)
                coordinate("Width", \.width, fallback: region)
                coordinate("Height", \.height, fallback: region)
            }
            if case .success(let plan) = layout {
                VideoCropCanvas(image: source.image, sourceSize: source.size, region: plan.region,
                                aspect: options.aspect) { options.region = $0 }
                    .id(source.url)
                    .frame(height: 250)
            }
        }
        if inputs.count > 1 {
            Text("Showing \(source.url.lastPathComponent). Crop coordinates apply to each video.")
                .font(.callout).foregroundStyle(.secondary)
        }
        switch layout {
        case .failure(let error):
            Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
        case .success(let plan):
            if let rendered, rendered.input == request {
                switch rendered.result {
                case .success(let image):
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Output · \(Int(plan.outputSize.width)) × \(Int(plan.outputSize.height))")
                            .font(.callout.weight(.medium))
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 360, maxHeight: 205, alignment: .topLeading)
                            .clipShape(.rect(cornerRadius: 6))
                            .accessibilityLabel("Output preview")
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Rendering preview…").controlSize(.small)
            }
        }
    }

    private func coordinate(_ label: String, _ keyPath: WritableKeyPath<VideoCropRegion, Int>,
                            fallback: VideoCropRegion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: Binding {
                (options.region ?? fallback)[keyPath: keyPath]
            } set: { value in
                var region = options.region ?? fallback
                region[keyPath: keyPath] = value
                options.region = region
            }, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 80)
        }
    }

    private func resetRegion() -> VideoCropOptions {
        var copy = options
        copy.region = nil
        return copy
    }

    private func loadSource(_ url: URL?) async {
        source = nil
        sourceIssue = nil
        guard let url else { return }
        do {
            async let size = VideoCrop.sourceSize(url)
            async let image = VideoCrop.sourcePreview(url)
            let loaded = try await SourcePreview(url: url, size: size, image: image)
            try Task.checkCancellation()
            source = loaded
        } catch {
            if !Task.isCancelled { sourceIssue = error.localizedDescription }
        }
    }

    private func render(_ request: PreviewInput) async {
        guard let url = request.url else { return }
        do {
            try await Task.sleep(for: .milliseconds(150))
            let image = try await VideoCrop.preview(url, options: request.options)
            try Task.checkCancellation()
            rendered = RenderedPreview(input: request, result: .success(image))
        } catch {
            if !Task.isCancelled { rendered = RenderedPreview(input: request, result: .failure(error)) }
        }
    }
}
