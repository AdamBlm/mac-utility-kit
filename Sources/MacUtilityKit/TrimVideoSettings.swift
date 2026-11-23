import AVKit
import Combine
import SwiftUI
import UtilityCore

struct TrimVideoReview {
    let inputs: [URL]
    let options: TrimVideoOptions
    let ranges: [Result<VideoTrimRange, Error>]
    let sourceVersions: [Int: LocalInputFile.Version]

    var permitsExport: Bool { ranges.contains { (try? $0.get()) != nil } }
}

struct TrimVideoSettings: View {
    let inputs: [URL]
    @Binding var review: TrimVideoReview?
    private var input: URL? {
        if let previewInput, inputs.contains(previewInput) { return previewInput }
        return inputs.first
    }
    @Binding var options: TrimVideoOptions
    @State private var player = AVPlayer()
    @State private var previewInput: URL?
    @State private var scrubTime = 0.0
    @State private var timeObserver: Any?
    @State private var pendingSeek: UUID?
    @State private var startText: String?
    @State private var endText: String?
    @State private var loadedDuration: Double?
    @State private var loadedInput: URL?
    @State private var previewReady = false
    @State private var playbackError: String?

    private struct Request: Equatable {
        let inputs: [URL]
        let options: TrimVideoOptions
    }

    private var format: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(0...3))
    }

    private var activeDuration: Double? {
        loadedInput == input ? loadedDuration : nil
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
        if inputs.count > 1 {
            SettingRow("Preview file") {
                Picker("Preview file", selection: Binding(get: { input }, set: { previewInput = $0 })) {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { index, file in
                        Text("\(index + 1). \(file.lastPathComponent)").tag(Optional(file))
                    }
                }
                .labelsHidden()
            }
        }
        if let duration = activeDuration, let item = player.currentItem, playbackError == nil {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, minHeight: 180, idealHeight: 240)
                .onReceive(item.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
                    guard item === player.currentItem else { return }
                    previewReady = status == .readyToPlay
                    if status == .failed { playbackFailed(item.error, item: item) }
                }
                .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                                 object: item).receive(on: DispatchQueue.main)) { note in
                    playbackFailed(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error, item: item)
                }
            Slider(value: Binding(get: { scrubTime }, set: { seek(to: $0) }), in: 0...duration)
                .accessibilityLabel("Scrub video")
                .disabled(!previewReady)
            HStack {
                Text("\(scrubTime.formatted(format)) s").monospacedDigit()
                Spacer()
                Button("Set In") {
                    startText = nil
                    options.start = markTime()
                }
                Button("Set Out") {
                    endText = nil
                    options.end = markTime()
                }
            }
            .disabled(!previewReady)
        }
        SettingRow("In point") {
            TextField("In point timecode", text: Binding(
                get: { startText ?? fieldText(options.start) },
                set: {
                    startText = $0
                    options.start = VideoTimecode.seconds(from: $0) ?? -1
                }
            ))
            .frame(width: 98)
            .help("Seconds, MM:SS, or HH:MM:SS")
        }
        SettingRow("Out point") {
            if let end = options.end {
                TextField("Out point timecode", text: Binding(
                    get: { endText ?? fieldText(end) },
                    set: {
                        endText = $0
                        options.end = VideoTimecode.seconds(from: $0) ?? -1
                    }
                ))
                .frame(width: 98)
                .help("Seconds, MM:SS, or HH:MM:SS")
                Button("Use End") {
                    endText = nil
                    options.end = nil
                }
            } else {
                Text("End of video").foregroundStyle(.secondary)
                Button("Set Time") { options.end = activeDuration ?? options.start + 1 }
            }
        }
        if options.start < 0 || (options.end ?? 0) < 0 {
            Text("Enter seconds, MM:SS, or HH:MM:SS.")
                .font(.callout).foregroundStyle(.red)
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
                    Text("\(index + 1). \(source.lastPathComponent)").font(.callout.weight(.medium)).lineLimit(1)
                }
                switch result {
                case .success(let planned):
                    Text("\(label): \(planned.start.formatted(format))–\(planned.end.formatted(format)) s")
                        .font(.callout).monospacedDigit()
                    if source == input {
                        Button("Preview Selection", systemImage: "play.fill") { seek(to: planned.start, playTo: planned.end) }
                            .disabled(activeDuration == nil || !previewReady)
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
            .onAppear { observePlayhead() }
            .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
                .receive(on: DispatchQueue.main)) { notification in
                guard let item = notification.object as? AVPlayerItem,
                      item === player.currentItem, pendingSeek == nil, player.rate == 0,
                      item.forwardPlaybackEndTime.isNumeric,
                      abs(player.currentTime().seconds - item.forwardPlaybackEndTime.seconds) < 0.001 else { return }
                item.forwardPlaybackEndTime = .invalid
            }
            .onDisappear {
                pauseAndCancelSeek()
                if let timeObserver { player.removeTimeObserver(timeObserver) }
                timeObserver = nil
            }
    }

    private func fieldText(_ value: Double) -> String {
        value < 0 ? "" : value.formatted(format)
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
        guard !Task.isCancelled else { return }
        pauseAndCancelSeek()
        player.replaceCurrentItem(with: nil)
        scrubTime = 0
        loadedDuration = nil
        loadedInput = nil
        previewReady = false
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
            loadedInput = url
        } catch {
            if !Task.isCancelled { playbackError = "Preview is unavailable for this video." }
        }
    }

    private func plan(_ request: Request) async {
        guard !Task.isCancelled else { return }
        pauseAndCancelSeek()
        guard !request.inputs.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            var ranges: [Result<VideoTrimRange, Error>] = []
            var sourceVersions: [Int: LocalInputFile.Version] = [:]
            for (index, input) in request.inputs.enumerated() {
                do {
                    let version = try LocalInputFile.Version.read(input)
                    sourceVersions[index] = version
                    let range = try await TrimVideo.plannedRange(input, options: request.options)
                    guard (try? LocalInputFile.Version.read(input)) == version else {
                        throw ToolError.invalid("The video changed during trim review. Remove it and add it again.")
                    }
                    ranges.append(.success(range))
                } catch {
                    try Task.checkCancellation()
                    ranges.append(.failure(error))
                }
            }
            try Task.checkCancellation()
            review = TrimVideoReview(inputs: request.inputs, options: request.options, ranges: ranges,
                                     sourceVersions: sourceVersions)
        } catch {
            return
        }
    }

    private func pauseAndCancelSeek() {
        pendingSeek = nil
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }

    private func playbackFailed(_ error: Error?, item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        pauseAndCancelSeek()
        previewReady = false
        playbackError = error?.localizedDescription ?? "Preview is unavailable for this video."
    }

    private func observePlayhead() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { _ in
            MainActor.assumeIsolated {
                let seconds = player.currentTime().seconds
                if pendingSeek == nil, let duration = loadedDuration, seconds.isFinite {
                    scrubTime = min(duration, max(0, seconds))
                }
            }
        }
    }

    private func markTime() -> Double {
        guard let duration = activeDuration else { return 0 }
        let current = player.currentTime().seconds
        return pendingSeek == nil && current.isFinite ? min(duration, max(0, current)) : scrubTime
    }

    private func seek(to seconds: Double, playTo end: Double? = nil) {
        guard previewReady, let item = player.currentItem, let duration = activeDuration else { return }
        pauseAndCancelSeek()
        let request = UUID()
        pendingSeek = request
        scrubTime = min(duration, max(0, seconds))
        if let end { item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 1_000_000) }
        player.seek(to: CMTime(seconds: scrubTime, preferredTimescale: 1_000_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                guard pendingSeek == request, player.currentItem === item else { return }
                pendingSeek = nil
                if finished, end != nil { player.play() }
            }
        }
    }
}
