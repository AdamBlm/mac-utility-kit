import SwiftUI
import UtilityCore

struct FrameExtractionSettings: View {
    let input: URL?
    @Binding var options: FrameExtractionOptions
    @State private var seconds = 0.0
    @State private var loaded: LoadedVideo?
    @State private var preview: CGImage?
    @State private var previewError: String?

    private struct LoadedVideo {
        let input: URL
        let bounds: Range<Double>?
        let error: String?
    }

    private struct PreviewRequest: Equatable {
        let input: URL
        let time: Double
    }

    private var activeVideo: LoadedVideo? { loaded?.input == input ? loaded : nil }

    private var request: PreviewRequest? {
        guard let input, let bounds = activeVideo?.bounds, seconds.isFinite,
              bounds.contains(seconds) else { return nil }
        return PreviewRequest(input: input, time: seconds)
    }

    private var timestampFormat: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(0...3))
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
                TextField("Interval", value: $options.interval, format: timestampFormat)
                    .frame(width: 90)
                Text("seconds").foregroundStyle(.secondary)
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
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .accessibilityLabel("Frame preview")
            }
            if let previewError { Text(previewError).font(.callout).foregroundStyle(.secondary) }
            Slider(value: Binding(get: { min(max(bounds.lowerBound, seconds), maximum) },
                                  set: { seconds = $0 }), in: bounds.lowerBound...maximum)
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
            TextField("Timestamp in seconds", value: $seconds, format: timestampFormat)
                .frame(width: 90)
            Text("seconds").foregroundStyle(.secondary)
            Button("Add", systemImage: "plus") {
                options.timestamps.append(seconds)
                options.timestamps.sort()
            }
            .disabled(!canAddTimestamp)
        }
        if options.timestamps.isEmpty {
            Text("Extracts the first frame when the timestamp list is empty.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(options.timestamps.indices, id: \.self) { index in
            let time = options.timestamps[index]
            HStack {
                Button("\(time.formatted(timestampFormat)) s") { seconds = time }
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

    private var canAddTimestamp: Bool {
        guard seconds.isFinite, seconds >= 0, options.timestamps.count < FrameExtraction.maximumFrames,
              !options.timestamps.contains(seconds) else { return false }
        return activeVideo?.bounds?.contains(seconds) == true
    }

    private func scrubMaximum(_ bounds: Range<Double>) -> Double {
        let duration = bounds.upperBound - bounds.lowerBound
        return min(bounds.upperBound.nextDown, bounds.upperBound - min(0.001, duration * 0.000_001))
    }

    private func load(_ url: URL?) async {
        preview = nil
        previewError = nil
        loaded = nil
        guard let url else { return }
        do {
            let bounds = try await FrameExtraction.timeBounds(of: url)
            guard !Task.isCancelled else { return }
            if !seconds.isFinite || !bounds.contains(seconds) { seconds = bounds.lowerBound }
            loaded = LoadedVideo(input: url, bounds: bounds, error: nil)
        } catch {
            if !Task.isCancelled { loaded = LoadedVideo(input: url, bounds: nil, error: error.localizedDescription) }
        }
    }

    private func updatePreview(_ request: PreviewRequest?) async {
        previewError = nil
        guard let request else {
            preview = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(90))
            let image = try await FrameExtraction.preview(request.input, at: request.time)
            if !Task.isCancelled { preview = image }
        } catch {
            if !Task.isCancelled {
                preview = nil
                previewError = error.localizedDescription
            }
        }
    }
}
