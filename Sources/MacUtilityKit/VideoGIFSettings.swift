import AppKit
import SwiftUI
import UtilityCore

struct VideoGIFSettings: View {
    let inputs: [URL]
    @Binding var options: VideoGIFOptions
    @State private var selectedSource: URL?
    @State private var reviewedInputs: [URL] = []
    @State private var sources: [URL: Source] = [:]
    @State private var scrubTime = 0.0
    @State private var sourceFrame: (request: ScrubRequest, result: Result<CGImage, Error>)?
    @State private var startText: String?
    @State private var endText: String?
    @State private var preview: VideoGIFPreview?
    @State private var activePreview: Request?
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?

    private struct Source {
        let bounds: Range<Double>?
        let error: String?
    }

    private var previewInputs: [URL] {
        var seen = Set<URL>()
        return inputs.filter { seen.insert($0).inserted }
    }

    private var input: URL? {
        selectedSource.flatMap { inputs.contains($0) ? $0 : nil } ?? inputs.first
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
        let source = reviewedInputs == inputs ? input.flatMap { sources[$0] } : nil
        if previewInputs.count > 1 {
            SettingRow("Preview video") {
                Picker("Preview video", selection: Binding(get: { input }, set: { selectedSource = $0 })) {
                    ForEach(previewInputs, id: \.self) { url in
                        Text(previewLabel(url)).tag(Optional(url))
                    }
                }
                .labelsHidden()
                .help(input?.path ?? "")
            }
            Text("Clip settings apply to every queued video.")
                .font(.callout).foregroundStyle(.secondary)
        }
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
        .task(id: inputs) { await load(inputs) }
        .onChange(of: input) {
            sourceFrame = nil
            scrubTime = 0
        }
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

        let settingsIssue = options.settingsIssue
        if let settingsIssue {
            Text(settingsIssue).foregroundStyle(.red).font(.callout)
        } else if inputs.count > 1 {
            batchReview
        }
        if let input, let bounds = source?.bounds {
            clipScrubber(input, bounds: bounds)
            if settingsIssue == nil {
                switch Result(catching: { try VideoGIF.plan(in: bounds, options: options) }) {
                case .success(let plan):
                    previewControls(request, plan: plan)
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(.red).font(.callout)
                }
            }
        } else if let error = source?.error {
            Text(error).foregroundStyle(.red).font(.callout)
        } else if input != nil && inputs.count == 1 {
            ProgressView("Reading video…").controlSize(.small)
        }
    }

    @ViewBuilder
    private var batchReview: some View {
        if reviewedInputs != inputs || !inputs.allSatisfy({ sources[$0] != nil }) {
            ProgressView("Checking GIF ranges…").controlSize(.small)
        } else {
            let plans = inputs.map { url -> (file: URL, plan: VideoGIFPlan?, issue: String?) in
                guard let bounds = sources[url]?.bounds else { return (url, nil, sources[url]?.error) }
                do {
                    return (url, try VideoGIF.plan(in: bounds, options: options), nil)
                } catch {
                    return (url, nil, error.localizedDescription)
                }
            }
            let invalid = plans.count { $0.issue != nil }
            let large = plans.count { $0.plan?.shouldWarnAboutSize == true }
            DisclosureGroup("Per-file GIF plan") {
                ForEach(Array(plans.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1). \(row.file.lastPathComponent)").lineLimit(1).help(row.file.path)
                        if let plan = row.plan {
                            Text("\(plan.frameCount) frames" + (plan.shouldWarnAboutSize ? " · May be large" : ""))
                                .foregroundStyle(.secondary)
                        } else if let issue = row.issue {
                            Text(issue).foregroundStyle(.red)
                        }
                    }
                    .font(.callout)
                }
            }
            if invalid > 0 {
                Text(invalid == 1 ? "1 video cannot use these settings." : "\(invalid) videos cannot use these settings.")
                    .font(.callout).foregroundStyle(.red)
            }
            if large > 0 {
                Text(large == 1 ? "1 animation may be large." : "\(large) animations may be large.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func previewLabel(_ url: URL) -> String {
        let name = url.lastPathComponent
        return previewInputs.contains { $0 != url && $0.lastPathComponent == name } ? url.path : name
    }

    @ViewBuilder
    private func clipScrubber(_ input: URL, bounds: Range<Double>) -> some View {
        let margin = min(0.001, (bounds.upperBound - bounds.lowerBound) * 0.000_001)
        let maximum = max(bounds.lowerBound, min(bounds.upperBound.nextDown, bounds.upperBound - margin))
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
        if maximum > bounds.lowerBound {
            Slider(value: Binding(get: { request.time }, set: { scrubTime = $0 }), in: bounds.lowerBound...maximum)
                .accessibilityLabel("Scrub source video")
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
        .task(id: request) {
            do {
                try await Task.sleep(for: .milliseconds(110))
                let image = try await FrameExtraction.preview(request.input, at: request.time)
                if !Task.isCancelled { sourceFrame = (request, .success(image)) }
            } catch {
                if !Task.isCancelled { sourceFrame = (request, .failure(error)) }
            }
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

    private func load(_ inputs: [URL]) async {
        guard !Task.isCancelled else { return }
        reviewedInputs = inputs
        sources = [:]
        scrubTime = 0
        sourceFrame = nil
        for url in inputs where sources[url] == nil {
            let source: Source
            do {
                source = Source(bounds: try await FrameExtraction.timeBounds(of: url), error: nil)
            } catch {
                source = Source(bounds: nil, error: error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            sources[url] = source
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
