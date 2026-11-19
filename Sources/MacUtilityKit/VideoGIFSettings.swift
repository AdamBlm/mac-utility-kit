import AppKit
import SwiftUI
import UtilityCore

struct VideoGIFSettings: View {
    let input: URL?
    @Binding var options: VideoGIFOptions
    @State private var loaded: Source?
    @State private var scrubTime = 0.0
    @State private var sourceFrame: CGImage?
    @State private var preview: VideoGIFPreview?
    @State private var activePreview: Request?
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?

    private struct Source {
        let url: URL
        let bounds: Range<Double>?
        let error: String?
    }

    private struct Request: Equatable, Sendable {
        let input: URL?
        let options: VideoGIFOptions
    }

    private struct ScrubRequest: Equatable {
        let input: URL
        let time: Double
    }

    private var format: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(0...3))
    }

    var body: some View {
        let request = Request(input: input, options: options)
        let source = loaded?.url == input ? loaded : nil
        SettingRow("In point") {
            TextField("In point in seconds", value: Binding(
                get: { options.start == 0 ? source?.bounds?.lowerBound ?? 0 : options.start },
                set: { options.start = $0 }
            ), format: format)
                .frame(width: 80)
            Text("seconds").foregroundStyle(.secondary)
        }
        .task(id: input) { await load(input) }
        SettingRow("Out point") {
            if let end = options.end {
                TextField("Out point in seconds", value: Binding(
                    get: { options.end ?? end }, set: { options.end = $0 }
                ), format: format)
                .frame(width: 80)
                Text("seconds").foregroundStyle(.secondary)
                Button("Use End") { options.end = nil }
            } else {
                if let duration = source?.bounds?.upperBound {
                    Text("End of video (\(duration.formatted(format)) s)").foregroundStyle(.secondary)
                } else {
                    Text("End of video").foregroundStyle(.secondary)
                }
                Button("Set Time") { options.end = source?.bounds?.upperBound ?? options.start + 1 }
            }
        }
        SettingRow("Maximum width") {
            TextField("Maximum width in pixels", value: $options.width, format: .number.grouping(.never))
                .frame(width: 80)
            Text("pixels").foregroundStyle(.secondary)
        }
        SettingRow("Frame rate") {
            TextField("Frames per second", value: $options.fps, format: .number.grouping(.never))
                .frame(width: 80)
            Text("fps").foregroundStyle(.secondary)
        }
        SettingRow("Palette") {
            Picker("Palette", selection: $options.palette) {
                ForEach(GIFPalette.allCases) { Text("\($0.rawValue) colors").tag($0) }
            }
            .labelsHidden()
        }
        Toggle("Dither palette colors", isOn: $options.dithering)
        SettingRow("Playback") {
            Picker("Playback", selection: $options.loop) {
                ForEach(GIFLoop.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            if options.loop == .repeatCount {
                TextField("Additional repeats", value: $options.repetitions, format: .number.grouping(.never))
                    .frame(width: 48)
                Text("times").foregroundStyle(.secondary)
            }
        }
        executablePicker("FFmpeg", selection: $options.ffmpegExecutable)
            .onChange(of: request) { clearPreview() }
            .onDisappear { clearPreview() }
        if let issue = options.engineIssue {
            Text(issue).font(.callout).foregroundStyle(.secondary)
        }

        if let input, let bounds = source?.bounds {
            clipScrubber(input, bounds: bounds)
            switch Result(catching: { try VideoGIF.plan(in: bounds, options: options) }) {
            case .success(let plan):
                previewControls(request, plan: plan)
            case .failure(let error):
                Text(error.localizedDescription).foregroundStyle(.red).font(.callout)
            }
        } else if let error = source?.error {
            Text(error).foregroundStyle(.red).font(.callout)
        }
    }

    @ViewBuilder
    private func clipScrubber(_ input: URL, bounds: Range<Double>) -> some View {
        if let sourceFrame {
            Image(decorative: sourceFrame, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 160)
                .accessibilityLabel("Source frame")
        }
        let maximum = max(bounds.lowerBound, min(bounds.upperBound.nextDown, bounds.upperBound - 0.001))
        let request = ScrubRequest(input: input, time: min(max(scrubTime, bounds.lowerBound), maximum))
        Slider(value: Binding(get: { request.time }, set: { scrubTime = $0 }), in: bounds.lowerBound...maximum)
            .accessibilityLabel("Scrub source video")
            .task(id: request) {
                do {
                    try await Task.sleep(for: .milliseconds(110))
                    let image = try await FrameExtraction.preview(request.input, at: request.time)
                    if !Task.isCancelled { sourceFrame = image }
                } catch {
                    if !Task.isCancelled { sourceFrame = nil }
                }
            }
        HStack {
            Text("\(scrubTime.formatted(format)) s").monospacedDigit()
            Spacer()
            Button("Set In") { options.start = scrubTime }
            Button("Set Out") { options.end = scrubTime }
        }
    }

    @ViewBuilder
    private func previewControls(_ request: Request, plan: VideoGIFPlan) -> some View {
        if plan.shouldWarnAboutSize {
            Label("This animation may be large. Shorter clips, lower widths, or fewer frames reduce its size.",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let input, request.options.engineIssue == nil {
            Button("Generate Preview", systemImage: "play.rectangle") {
                generatePreview(for: request, input: input)
            }
            .disabled(previewTask != nil)
        }
        if activePreview == request {
            if previewTask != nil { ProgressView("Encoding preview…").controlSize(.small) }
            if let preview {
                GIFAnimationView(data: preview.data)
                    .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 210, maxHeight: 300)
                    .accessibilityLabel("GIF animation preview")
                let bytes = preview.estimatedBytes.formatted(.byteCount(style: .file))
                Text(preview.showsFullClip
                     ? "GIF size: \(bytes)"
                     : "Estimated full GIF size: \(bytes) · first \(preview.duration.formatted(format)) seconds shown")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let previewError {
                Text(previewError).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func load(_ input: URL?) async {
        loaded = nil
        scrubTime = 0
        sourceFrame = nil
        guard let input else { return }
        do {
            let bounds = try await FrameExtraction.timeBounds(of: input)
            guard !Task.isCancelled else { return }
            scrubTime = bounds.lowerBound
            loaded = Source(url: input, bounds: bounds, error: nil)
        } catch {
            if !Task.isCancelled { loaded = Source(url: input, bounds: nil, error: error.localizedDescription) }
        }
    }

    private func generatePreview(for request: Request, input: URL) {
        clearPreview()
        activePreview = request
        previewTask = Task {
            do {
                let result = try await VideoGIF.preview(input, options: request.options)
                if !Task.isCancelled { preview = result }
            } catch {
                if !Task.isCancelled { previewError = error.localizedDescription }
            }
            if !Task.isCancelled { previewTask = nil }
        }
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        activePreview = nil
        preview = nil
        previewError = nil
    }
}

private struct GIFAnimationView: NSViewRepresentable {
    let data: Data

    final class Coordinator {
        var data: Data?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.animates = false
        view.image = NSImage(data: data)
        view.animates = true
    }
}
