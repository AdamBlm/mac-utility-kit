import SwiftUI
import UtilityCore

struct ImageRotateControls: View {
    let inputs: [URL]
    @Binding var options: ImageRotateOptions
    @State private var selected: URL?
    @State private var preview: PreviewResult?

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
            SettingRow("Format") {
                Picker("Output format", selection: $options.output) {
                    ForEach(ImageRotateOptions.Output.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            if options.output == .original && inputs.contains(where: {
                ["jpeg", "jpg", "heic", "heif", "hif"].contains($0.pathExtension.lowercased())
            }) {
                SettingRow("Quality") {
                    Slider(value: $options.quality, in: 0.05...1, step: 0.01) { Text("JPEG and HEIC quality") }
                        .labelsHidden()
                    Text(options.quality.formatted(.percent.precision(.fractionLength(0))))
                        .font(.callout.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
            }
            Toggle("Preserve compatible metadata", isOn: $options.preserveMetadata)
            if inputs.count > 1 {
                SettingRow("Preview file") {
                    Picker("Preview file", selection: Binding(get: { input }, set: { selected = $0 })) {
                        ForEach(Array(inputs.enumerated()), id: \.offset) { _, url in
                            Text(url.lastPathComponent).tag(Optional(url))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let preview, preview.request == request {
                switch preview.result {
                case .success(let pair):
                    HStack(alignment: .top, spacing: 12) {
                        tile("Original", image: pair.before, width: pair.sourceWidth, height: pair.sourceHeight)
                        tile("Rotated", image: pair.after, width: pair.outputWidth, height: pair.outputHeight)
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            } else if input != nil {
                ProgressView("Loading image preview…").controlSize(.small)
            }
        }
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

    private func tile(_ title: String, image: CGImage, width: Int, height: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            Text("\(width) × \(height)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 195)
                .padding(5)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(title + " preview")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
