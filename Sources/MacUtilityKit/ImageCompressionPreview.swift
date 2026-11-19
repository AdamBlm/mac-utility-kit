import SwiftUI
import UtilityCore

struct ImageCompressionPreviewControls: View {
    let inputs: [URL]
    let options: ImageCompressionOptions
    @State private var selection: URL?
    @State private var sample: ImageCompressionPreview.Request?

    private var sources: [URL] {
        var seen = Set<URL>()
        return inputs.filter { seen.insert($0).inserted }
    }

    private var source: URL? {
        if let selection, inputs.contains(selection) { return selection }
        return inputs.first
    }

    var body: some View {
        if let source {
            if sources.count > 1 {
                SettingRow("Preview file") {
                    Picker("Preview file", selection: Binding(get: { self.source }, set: { selection = $0 })) {
                        ForEach(Array(sources.enumerated()), id: \.element) { index, input in
                            Text("\(index + 1). \(input.lastPathComponent)").tag(Optional(input))
                        }
                    }
                    .labelsHidden()
                }
            }
            Button("Preview Compression", systemImage: "rectangle.split.2x1") {
                sample = .init(input: source, options: options)
            }
            .disabled(options.format.requiresImageMagick && options.imageMagickExecutable == nil)
            .sheet(item: $sample) { request in
                ImageCompressionPreview(request: request)
            }
        }
    }
}

private struct ImageCompressionPreview: View {
    struct Request: Identifiable {
        let id = UUID()
        let input: URL
        let options: ImageCompressionOptions
    }

    let request: Request
    @Environment(\.dismiss) private var dismiss
    @State private var sample: ImageCompressionSample?
    @State private var issue: String?

    var body: some View {
        Group {
            if let sample {
                ImageComparisonView(pair: sample.comparison, summary: sample.summary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if let issue {
                        Text(issue).textSelection(.enabled)
                    } else {
                        ProgressView("Compressing preview…").controlSize(.small)
                    }
                    Button(issue == nil ? "Cancel" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(22)
                .frame(minWidth: 360)
            }
        }
        .task { await prepare() }
        .onDisappear { sample = nil }
    }

    private func prepare() async {
        do {
            let rendered = try await ImageCompressionSample.make(request.input, options: request.options)
            try Task.checkCancellation()
            sample = rendered
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }
}
