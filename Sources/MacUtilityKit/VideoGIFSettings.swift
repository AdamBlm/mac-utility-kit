import AppKit
import SwiftUI
import UtilityCore

struct VideoGIFSettings: View {
    let input: URL?
    @Binding var options: VideoGIFOptions
    @State private var loaded: Source?
    @State private var scrubTime = 0.0
    @State private var sourceFrame: (request: ScrubRequest, result: Result<CGImage, Error>)?
    @State private var startText: String?
    @State private var endText: String?
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
        .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...3))
    }

    var body: some View {
        let request = Request(input: input, options: options)
        let source = loaded?.url == input ? loaded : nil
        SettingRow("In point") {
            TextField("In point", text: Binding(
                get: { startText ?? (options.start == 0 ? source?.bounds?.lowerBound ?? 0 : options.start).formatted(format) },
                set: {
                    startText = $0
                    options.start = VideoTimecode.seconds(from: $0) ?? -1
                }
            ))
                .frame(width: 80)
                .help("Seconds, MM:SS, or HH:MM:SS. Zero starts at the first visible frame.")
        }
        .task(id: input) { await load(input) }
        if options.start == 0, let start = source?.bounds?.lowerBound, start > 0 {
            Text("Starts at the first visible frame (\(start.formatted(format)) s).")
                .font(.caption).foregroundStyle(.secondary)
        }
        SettingRow("Out point") {
            if let end = options.end {
                TextField("Out point", text: Binding(
                    get: { endText ?? end.formatted(format) },
                    set: {
                        endText = $0
                        options.end = VideoTimecode.seconds(from: $0) ?? -1
                    }
                ))
                .frame(width: 80)
                .help("Seconds, MM:SS, or HH:MM:SS")
                Button("Use End") {
                    endText = nil
                    options.end = nil
                }
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
            GIFIntegerField(label: "Maximum width in pixels", value: $options.width)
                .frame(width: 80)
            Text("pixels").foregroundStyle(.secondary)
        }
        SettingRow("Frame rate") {
            GIFIntegerField(label: "Frames per second", value: $options.fps)
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
                GIFIntegerField(label: "Additional repeats", value: $options.repetitions)
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
        let maximum = max(bounds.lowerBound, min(bounds.upperBound.nextDown, bounds.upperBound - 0.001))
        let request = ScrubRequest(input: input, time: min(max(scrubTime, bounds.lowerBound), maximum))
        if let sourceFrame, sourceFrame.request == request, case .success(let image) = sourceFrame.result {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 160)
                .accessibilityLabel("Source frame")
        } else if let sourceFrame, sourceFrame.request == request, case .failure(let error) = sourceFrame.result {
            Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
        } else {
            ProgressView("Preparing source frame…").controlSize(.small)
        }
        Slider(value: Binding(get: { request.time }, set: { scrubTime = $0 }), in: bounds.lowerBound...maximum)
            .accessibilityLabel("Scrub source video")
            .task(id: request) {
                do {
                    try await Task.sleep(for: .milliseconds(110))
                    let image = try await FrameExtraction.preview(request.input, at: request.time)
                    if !Task.isCancelled { sourceFrame = (request, .success(image)) }
                } catch {
                    if !Task.isCancelled { sourceFrame = (request, .failure(error)) }
                }
            }
        HStack {
            Text("\(request.time.formatted(format)) s").monospacedDigit()
            Spacer()
            Button("Set In") {
                startText = nil
                options.start = request.time
            }
            Button("Set Out") {
                endText = nil
                options.end = request.time
            }
        }
        .disabled(sourceFrame?.request != request || (try? sourceFrame?.result.get()) == nil)
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
        guard !Task.isCancelled else { return }
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

private struct GIFIntegerField: View {
    let label: String
    @Binding var value: Int
    @State private var text: String?

    var body: some View {
        TextField(label, text: Binding(
            get: { text ?? (value == 0 ? "" : String(value)) },
            set: {
                text = $0
                value = Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        ))
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
