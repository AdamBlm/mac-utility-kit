import AVKit
import SwiftUI
import UtilityCore

struct TrimVideoReview {
    let inputs: [URL]
    let options: TrimVideoOptions
    let ranges: [Result<VideoTrimRange, Error>]

    var permitsExport: Bool { ranges.contains { (try? $0.get()) != nil } }
}

struct TrimVideoSettings: View {
    let inputs: [URL]
    @Binding var review: TrimVideoReview?
    private var input: URL? { inputs.first }
    @Binding var options: TrimVideoOptions
    @State private var player = AVPlayer()
    @State private var scrubTime = 0.0
    @State private var loadedDuration: Double?
    @State private var playbackError: String?

    private struct Request: Equatable {
        let inputs: [URL]
        let options: TrimVideoOptions
    }

    private var format: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(0...3))
    }

    var body: some View {
        let request = Request(inputs: inputs, options: options)
        SettingRow("Method") {
            Picker("Method", selection: $options.mode) {
                ForEach(VideoTrimMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }
        .task(id: input) { await load(input) }
        if let duration = loadedDuration {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, minHeight: 180, idealHeight: 240)
            Slider(value: $scrubTime, in: 0...duration)
                .accessibilityLabel("Scrub video")
                .onChange(of: scrubTime) {
                    player.pause()
                    if let item = player.currentItem {
                        item.forwardPlaybackEndTime = .invalid
                        item.cancelPendingSeeks()
                        player.seek(to: CMTime(seconds: scrubTime, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            HStack {
                Text("\(scrubTime.formatted(format)) s").monospacedDigit()
                Spacer()
                Button("Set In") { options.start = scrubTime }
                Button("Set Out") { options.end = scrubTime }
            }
        }
        SettingRow("In point") {
            TextField("In point in seconds", value: $options.start, format: format)
                .frame(width: 88)
            Text("seconds").foregroundStyle(.secondary)
        }
        SettingRow("Out point") {
            if let end = options.end {
                TextField("Out point in seconds", value: Binding(
                    get: { options.end ?? end }, set: { options.end = $0 }
                ), format: format)
                .frame(width: 88)
                Text("seconds").foregroundStyle(.secondary)
                Button("Use End") { options.end = nil }
            } else {
                Text("End of video").foregroundStyle(.secondary)
                Button("Set Time") { options.end = loadedDuration ?? options.start + 1 }
            }
        }
        if options.mode == .lossless {
            Text("Copies video and audio codecs to MKV. The start moves to the previous keyframe and the end moves to the next keyframe or the end of the video.")
                .font(.callout).foregroundStyle(.secondary)
            executable("FFmpeg", path: $options.ffmpegExecutable)
            executable("ffprobe", path: $options.ffprobeExecutable)
        }
        if let review, review.inputs == inputs, review.options == options {
            let label = options.mode == .lossless ? "Adjusted selection" : "Selection"
            ForEach(Array(zip(inputs, review.ranges).enumerated()), id: \.offset) { index, entry in
                let (source, result) = entry
                if inputs.count > 1 {
                    Text(source.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                }
                switch result {
                case .success(let planned):
                    Text("\(label): \(planned.start.formatted(format))–\(planned.end.formatted(format)) s")
                        .font(.callout).monospacedDigit()
                    if index == 0 {
                        Button("Preview Selection", systemImage: "play.fill") { preview(planned) }
                            .disabled(loadedDuration == nil)
                    }
                case .failure(let issue):
                    Text(issue.localizedDescription).font(.callout).foregroundStyle(.red)
                }
            }
        } else if !inputs.isEmpty {
            ProgressView("Checking trim ranges…").controlSize(.small)
        }
        if let playbackError { Text(playbackError).font(.callout).foregroundStyle(.secondary) }
        Divider()
            .task(id: request) { await plan(request) }
            .onDisappear {
                player.pause()
                player.currentItem?.cancelPendingSeeks()
            }
    }

    private func executable(_ label: String, path: Binding<URL?>) -> some View {
        SettingRow(label) {
            if let value = path.wrappedValue {
                Text(value.lastPathComponent)
                    .lineLimit(1)
                    .help(value.path)
            }
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    path.wrappedValue = panel.url
                }
            }
            if path.wrappedValue != nil {
                Button("Remove", systemImage: "xmark.circle") { path.wrappedValue = nil }
                    .labelStyle(.iconOnly)
            }
        }
    }

    private func load(_ url: URL?) async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        scrubTime = 0
        loadedDuration = nil
        playbackError = nil
        guard let url else { return }
        do {
            let duration = try await TrimVideo.duration(of: url)
            guard !Task.isCancelled else { return }
            let asset = AVURLAsset(url: url, options: [
                AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
            ])
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            loadedDuration = duration
        } catch {
            if !Task.isCancelled { playbackError = "Preview is unavailable for this video." }
        }
    }

    private func plan(_ request: Request) async {
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        guard !request.inputs.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            var ranges: [Result<VideoTrimRange, Error>] = []
            for input in request.inputs {
                do {
                    ranges.append(.success(try await TrimVideo.plannedRange(input, options: request.options)))
                } catch {
                    try Task.checkCancellation()
                    ranges.append(.failure(error))
                }
            }
            try Task.checkCancellation()
            review = TrimVideoReview(inputs: request.inputs, options: request.options, ranges: ranges)
        } catch {
            return
        }
    }

    private func preview(_ range: VideoTrimRange) {
        guard let item = player.currentItem else { return }
        player.pause()
        item.cancelPendingSeeks()
        item.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 1_000_000)
        player.seek(to: CMTime(seconds: range.start, preferredTimescale: 1_000_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            Task { @MainActor in
                if player.currentItem === item { player.play() }
            }
        }
    }
}
