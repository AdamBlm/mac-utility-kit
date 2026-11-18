import SwiftUI
import UtilityCore

struct PDFCompressionControls: View {
    let inputs: [URL]
    @Binding var options: PDFCompressionOptions
    @State private var selected: URL?
    @State private var pending: Request?
    @State private var result: Measurement?

    private struct Request: Equatable {
        let id = UUID()
        let input: URL
        let options: PDFCompressionOptions
    }

    private struct Measurement {
        let request: Request
        let result: Result<PDFCompression.Sample, any Error>
    }

    private var previewInput: URL? {
        selected.flatMap { inputs.contains($0) ? $0 : nil } ?? inputs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Preset") {
                Picker("Compression preset", selection: $options.preset) {
                    ForEach(PDFCompressionOptions.Preset.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            SettingRow("Engine") {
                Picker("Compression engine", selection: $options.engine) {
                    ForEach(PDFCompressionOptions.Engine.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            if options.engine == .qpdf {
                executablePicker("qpdf", selection: $options.qpdfExecutable)
                Text(options.isLossless
                     ? "Compress PDF objects and streams without reducing image quality."
                     : "Optimize embedded JPEG images without changing their pixel dimensions. Requires qpdf 12.1+.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                executablePicker("Ghostscript", selection: $options.ghostscriptExecutable)
                Text("Reduce embedded image DPI. Use qpdf for interactive forms and annotations.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Image Settings") {
                imageSettings.padding(.top, 9)
            }
            Toggle("Use original PDF if compression saves no space", isOn: $options.keepsOriginalIfLarger)
            if let issue = options.validationIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
            estimate
        }
        .task(id: pending) {
            guard let pending else { return }
            do {
                let sample = try await PDFCompression.sample(pending.input, options: pending.options)
                try Task.checkCancellation()
                result = Measurement(request: pending, result: .success(sample))
            } catch {
                if !Task.isCancelled { result = Measurement(request: pending, result: .failure(error)) }
            }
            if self.pending == pending { self.pending = nil }
        }
        .onChange(of: previewInput) { pending = nil }
        .onChange(of: options) { pending = nil }
    }

    private var imageSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Set JPEG quality", isOn: Binding(get: { options.imageQuality != nil }, set: { enabled in
                options.imageQuality = enabled ? options.defaultQuality : nil
            }))
            if let quality = options.imageQuality {
                SettingRow("JPEG quality") {
                    Slider(value: Binding(get: { Double(quality) }, set: { options.imageQuality = Int($0) }),
                           in: 1...100, step: 1)
                        .accessibilityLabel("JPEG quality")
                    Text("\(quality)%").monospacedDigit().frame(width: 46, alignment: .trailing)
                }
            }
            if options.engine == .ghostscript {
                Toggle("Set target DPI", isOn: Binding(get: { options.imageDPI != nil }, set: { enabled in
                    options.imageDPI = enabled ? options.defaultDPI : nil
                }))
                SettingRow("Target DPI") {
                    if let dpi = options.imageDPI {
                        Stepper("\(dpi) DPI", value: Binding(get: { dpi }, set: { options.imageDPI = $0 }), in: 72...600, step: 6)
                    } else {
                        Text("\(options.defaultDPI) DPI").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var estimate: some View {
        if inputs.count > 1 {
            SettingRow("Estimate file") {
                Picker("Estimate file", selection: Binding(get: { previewInput }, set: { selected = $0 })) {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                        Text(input.lastPathComponent).tag(Optional(input))
                    }
                }
                .labelsHidden()
            }
        }
        HStack {
            Button("Estimate Size…", systemImage: "gauge") {
                if let previewInput { pending = Request(input: previewInput, options: options) }
            }
            .disabled(previewInput == nil || options.validationIssue != nil || pending != nil)
            if pending != nil {
                ProgressView().controlSize(.small)
                Button("Cancel") { pending = nil }
            }
        }
        if let result, result.request.input == previewInput, result.request.options == options, pending == nil {
            switch result.result {
            case .success(let sample):
                VStack(alignment: .leading, spacing: 6) {
                    Text(sample.samplePages == sample.totalPages
                         ? "Compressed size: \(bytes(sample.candidateBytes))"
                         : "Estimated compressed size: \(bytes(sample.estimatedBytes))")
                        .font(.callout.weight(.medium))
                    Text("\(sample.samplePages) of \(sample.totalPages) pages sampled · \(bytes(sample.originalBytes)) → \(bytes(sample.candidateBytes))")
                        .font(.callout).foregroundStyle(.secondary)
                    if sample.candidateBytes >= sample.originalBytes {
                        Text(options.keepsOriginalIfLarger
                             ? "The sample did not shrink. Export keeps the original PDF if the full result also saves no space."
                             : "The sample did not shrink.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let image = sample.preview {
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFit().frame(maxWidth: 380, maxHeight: 240)
                            .accessibilityLabel("First compressed sample page")
                    }
                }
            case .failure(let error):
                Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
