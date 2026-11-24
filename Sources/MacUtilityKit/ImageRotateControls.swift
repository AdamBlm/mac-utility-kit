import SwiftUI
import UtilityCore

struct ImageRotateControls: View {
    let inputs: [URL]
    @Binding var options: ImageRotateOptions
    @State private var selected: URL?
    @State private var preview: PreviewResult?
    @State private var reviewedInputs: [URL] = []
    @State private var supportsQuality = false
    @State private var cropExpanded = true

    private var previewInputs: [URL] {
        var seen = Set<URL>()
        return inputs.filter { seen.insert($0).inserted }
    }

    private struct PreviewRequest: Equatable, Sendable {
        let input: URL?
        let options: ImageRotateOptions
    }

    private struct PreviewResult {
        let request: PreviewRequest
        let result: Result<ImageRotate.Preview, any Error>
    }

    var body: some View {
        let input = selected.flatMap { inputs.contains($0) ? $0 : nil } ?? inputs.first
        let request = PreviewRequest(input: input, options: options)
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Rotation") {
                Picker("Rotation", selection: $options.turn) {
                    ForEach(ImageRotateOptions.Turn.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            HStack(spacing: 16) {
                Toggle("Flip horizontally", isOn: $options.flipHorizontally)
                Toggle("Flip vertically", isOn: $options.flipVertically)
            }
            Toggle("Crop images", isOn: Binding(get: { options.crop != nil }, set: { enabled in
                options.crop = enabled ? ImageCropOptions() : nil
            }))
            if let crop = Binding($options.crop) {
                DisclosureGroup("Crop Settings", isExpanded: $cropExpanded) {
                    cropControls(crop)
                }
            }
            SettingRow("Format") {
                Picker("Output format", selection: $options.output) {
                    ForEach(ImageRotateOptions.Output.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            if options.output == .original, reviewedInputs == inputs, supportsQuality {
                SettingRow("Quality") {
                    Slider(value: $options.quality, in: 0.05...1, step: 0.01) { Text("JPEG and HEIC quality") }
                        .labelsHidden()
                    Text(options.quality.formatted(.percent.precision(.fractionLength(0))))
                        .font(.callout.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
            }
            if options.crop == nil {
                Toggle("Preserve compatible metadata", isOn: $options.preserveMetadata)
            } else {
                Text("Cropped copies omit source metadata and embedded previews.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if previewInputs.count > 1 {
                SettingRow("Preview file") {
                    Picker("Preview file", selection: Binding(get: { input }, set: { selected = $0 })) {
                        ForEach(previewInputs, id: \.self) { url in
                            let name = url.lastPathComponent
                            let sharesName = previewInputs.contains { $0 != url && $0.lastPathComponent == name }
                            Text(sharesName ? url.path : name).tag(Optional(url))
                        }
                    }
                    .labelsHidden()
                    .help(input?.path ?? "")
                }
            }
            if let preview, preview.request == request {
                switch preview.result {
                case .success(let pair):
                    HStack(alignment: .top, spacing: 12) {
                        tile("Original", image: pair.before, width: pair.sourceWidth, height: pair.sourceHeight)
                        tile("Result · " + pair.format.title, image: pair.after, width: pair.outputWidth, height: pair.outputHeight)
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            } else if input != nil {
                ProgressView("Loading image preview…").controlSize(.small)
            }
        }
        .task(id: inputs) { await inspectFormats(inputs) }
        .task(id: request) {
            guard let input = request.input else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try ImageRotate.preview(input, options: request.options) }
                }.value
                try Task.checkCancellation()
                preview = PreviewResult(request: request, result: result)
            } catch {}
        }
    }

    private func cropControls(_ crop: Binding<ImageCropOptions>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow("Aspect ratio") {
                Picker("Aspect ratio", selection: crop.ratio) {
                    ForEach(ImageCropOptions.Ratio.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            if crop.wrappedValue.ratio == .freeform {
                cropSlider("Width", value: crop.width, range: 0.01...1)
                cropSlider("Height", value: crop.height, range: 0.01...1)
            } else {
                cropSlider("Crop size", value: crop.scale, range: 0.01...1)
            }
            cropSlider("Left to right", value: crop.horizontalPosition, range: 0...1)
            cropSlider("Top to bottom", value: crop.verticalPosition, range: 0...1)
        }
        .padding(.top, 5)
    }

    private func cropSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        SettingRow(label) {
            Slider(value: value, in: range, step: 0.01) { Text(label) }.labelsHidden()
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .font(.callout.monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func inspectFormats(_ inputs: [URL]) async {
        let worker = Task.detached(priority: .userInitiated) {
            let options = ImageRotateOptions()
            return Set(inputs).contains { input in
                guard !Task.isCancelled,
                      let format = try? ImageRotate.outputFormat(input, options: options) else { return false }
                return format == .jpg || format == .heic
            }
        }
        let supported = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        supportsQuality = supported
        reviewedInputs = inputs
    }

    private func tile(_ title: String, image: CGImage, width: Int, height: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            Text("\(width) × \(height)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            ImagePreviewViewport(image: image, maxHeight: 195) { _ in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .background(.primary.opacity(0.04))
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel(title + " preview")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
