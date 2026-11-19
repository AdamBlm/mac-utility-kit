import SwiftUI
import UtilityCore

struct FrameExtractionSettings: View {
    let input: URL?
    @Binding var options: FrameExtractionOptions
    @State private var seconds = 0.0
    @State private var loaded: LoadedVideo?
    @State private var timestampText: String?
    @State private var intervalText: String?
    @State private var rendered: Rendered?

    private struct LoadedVideo {
        let input: URL
        let bounds: Range<Double>?
        let error: String?
    }

    private struct PreviewRequest: Equatable {
        let input: URL
        let time: Double
    }

    private struct Rendered {
        let request: PreviewRequest
        let result: Result<CGImage, Error>
    }

    private var activeVideo: LoadedVideo? { loaded?.input == input ? loaded : nil }

    private var request: PreviewRequest? {
        guard let input, let bounds = activeVideo?.bounds, seconds.isFinite,
              bounds.contains(seconds) else { return nil }
        return PreviewRequest(input: input, time: seconds)
    }

    private var timestampFormat: FloatingPointFormatStyle<Double> {
        .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...3))
    }

    private var enteredTimestamp: Double? {
        guard let timestampText else { return seconds }
        return VideoTimecode.seconds(from: timestampText)
    }

    var body: some View {
        SettingRow("Select frames") {
            Picker("Select frames", selection: $options.selection) {
                ForEach(FrameSelection.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .task(id: input) { await load(input) }
        previewControls
        if options.selection == .timestamps {
            timestampControls
        } else {
            SettingRow("Every") {
                TextField("Interval", text: Binding(
                    get: { intervalText ?? options.interval.formatted(timestampFormat) },
                    set: { text in
                        intervalText = text
                        options.interval = VideoTimecode.seconds(from: text) ?? 0
                    }
                ))
                    .frame(width: 90)
                    .help("Seconds, MM:SS, or HH:MM:SS")
            }
        }
        if let bounds = activeVideo?.bounds {
            let plan = Result { try FrameExtraction.times(in: bounds, options: options) }
            switch plan {
            case .success(let times):
                let count = times.count
                Text(count == 1 ? "1 frame planned" : "\(count) frames planned")
                    .font(.callout).foregroundStyle(.secondary)
            case .failure(let error):
                Text(error.localizedDescription).font(.callout).foregroundStyle(.red)
            }
        } else if let error = activeVideo?.error {
            Text(error).font(.callout).foregroundStyle(.red)
        }
        SettingRow("Image format") {
            Picker("Image format", selection: $options.format) {
                ForEach(FrameImageFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        if options.format.supportsQuality {
            SettingRow("Quality") {
                Slider(value: $options.quality, in: 0...1, step: 0.01)
                    .accessibilityLabel("Image quality")
                Text(options.quality.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
        }
        SettingRow("Filename") {
            Picker("Filename", selection: $options.naming) {
                ForEach(FrameNaming.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var previewControls: some View {
        if let bounds = activeVideo?.bounds {
            let maximum = scrubMaximum(bounds)
            if let rendered, rendered.request == request, case .success(let preview) = rendered.result {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .accessibilityLabel("Frame preview")
            }
            if let rendered, rendered.request == request, case .failure(let error) = rendered.result {
                Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
            } else if request != nil, rendered?.request != request {
                ProgressView("Preparing frame…").controlSize(.small)
            }
            Slider(value: Binding(get: { min(max(bounds.lowerBound, seconds), maximum) },
                                  set: { setTimestamp($0) }), in: bounds.lowerBound...maximum)
                .accessibilityLabel("Scrub video")
                .task(id: request) { await updatePreview(request) }
            if options.selection == .interval {
                Text("Preview at \(seconds.formatted(timestampFormat)) seconds")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var timestampControls: some View {
        SettingRow("Timestamp") {
            TextField("Timestamp", text: Binding(
                get: { timestampText ?? seconds.formatted(timestampFormat) },
                set: { text in
                    timestampText = text
                    if let time = enteredTimestamp, activeVideo?.bounds?.contains(time) == true { seconds = time }
                }
            ))
                .frame(width: 90)
                .help("Seconds, MM:SS, or HH:MM:SS")
            Button("Add", systemImage: "plus") {
                guard let time = enteredTimestamp, canAddTimestamp else { return }
                options.timestamps.append(time)
                options.timestamps.sort()
            }
            .disabled(!canAddTimestamp)
        }
        if timestampText != nil {
            if let time = enteredTimestamp {
                if let bounds = activeVideo?.bounds, !bounds.contains(time) {
                    Text("Enter a timestamp within the video.").font(.callout).foregroundStyle(.red)
                }
            } else {
                Text("Enter seconds, MM:SS, or HH:MM:SS.").font(.callout).foregroundStyle(.red)
            }
        }
        if options.timestamps.isEmpty {
            Text("Extracts the first frame when the timestamp list is empty.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(options.timestamps.indices, id: \.self) { index in
            let time = options.timestamps[index]
            HStack {
                Button("\(time.formatted(timestampFormat)) s") { setTimestamp(time) }
                    .buttonStyle(.plain)
                    .monospacedDigit()
                    .help("Preview this timestamp")
                Spacer()
                Button("Remove timestamp", systemImage: "minus.circle") {
                    if options.timestamps.indices.contains(index) { options.timestamps.remove(at: index) }
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private func setTimestamp(_ time: Double) {
        timestampText = nil
        seconds = time
    }

    private var canAddTimestamp: Bool {
        guard let time = enteredTimestamp, time.isFinite, time >= 0,
              options.timestamps.count < FrameExtraction.maximumFrames,
              !options.timestamps.contains(time) else { return false }
        return activeVideo?.bounds?.contains(time) == true
    }

    private func scrubMaximum(_ bounds: Range<Double>) -> Double {
        let duration = bounds.upperBound - bounds.lowerBound
        return min(bounds.upperBound.nextDown, bounds.upperBound - min(0.001, duration * 0.000_001))
    }

    private func load(_ url: URL?) async {
        rendered = nil
        loaded = nil
        guard let url else { return }
        do {
            let bounds = try await FrameExtraction.timeBounds(of: url)
            guard !Task.isCancelled else { return }
            if let time = enteredTimestamp, bounds.contains(time) {
                seconds = time
            } else if !bounds.contains(seconds) {
                seconds = bounds.lowerBound
            }
            loaded = LoadedVideo(input: url, bounds: bounds, error: nil)
        } catch {
            if !Task.isCancelled { loaded = LoadedVideo(input: url, bounds: nil, error: error.localizedDescription) }
        }
    }

    private func updatePreview(_ request: PreviewRequest?) async {
        guard let request else {
            rendered = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(90))
            let image = try await FrameExtraction.preview(request.input, at: request.time)
            if !Task.isCancelled { rendered = Rendered(request: request, result: .success(image)) }
        } catch {
            if !Task.isCancelled {
                rendered = Rendered(request: request, result: .failure(error))
            }
        }
    }
}
