import AVFoundation
import SwiftUI
import UtilityCore

struct AudioTrimReview {
    let inputs: [URL]
    let sources: [Result<AudioTrimSource, any Error>]

    func issues(options: AudioTrimOptions) -> [(index: Int, error: any Error)] {
        sources.enumerated().compactMap { index, source in
            do {
                _ = try AudioTrimSelection.plan(source.get(), options: options)
                return nil
            } catch {
                return (index, error)
            }
        }
    }
}

struct AudioTrimControls: View {
    let inputs: [URL]
    @Binding var options: AudioTrimOptions
    @Binding var review: AudioTrimReview?
    @State private var refreshID = UUID()
    @State private var loaded: Loaded?
    @State private var player: AVAudioPlayer?
    @State private var previewError: String?
    @State private var looping = false
    @State private var playhead: Double?

    private struct Loaded {
        let url: URL
        let result: Result<AudioTrimWaveform, any Error>
    }

    private var input: URL? { inputs.first }

    var body: some View {
        let active = loaded?.url == input ? loaded : nil
        let activeReview = review?.inputs == inputs ? review : nil
        let issues = activeReview?.issues(options: options) ?? []
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Method") {
                Picker("Method", selection: Binding(get: { options.mode }, set: { selectMode($0) })) {
                    ForEach(AudioTrimMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            SettingRow("Format") {
                Picker("Format", selection: $options.format) {
                    ForEach(AudioTrimFormat.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            if options.mode == .lossless {
                Text("Copies PCM samples exactly, with the same WAV or AIFF format and bit depth.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if options.format == .m4a {
                Text("AAC encoding supports precise selections and fades.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let result = active?.result {
                switch result {
                case .success(let waveform):
                    waveformEditor(waveform)
                case .failure(let error):
                    if !issues.contains(where: { $0.index == 0 && $0.error.localizedDescription == error.localizedDescription }) {
                        Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else if input != nil {
                ProgressView("Reading waveform…").controlSize(.small)
            }
            if activeReview != nil {
                if !issues.isEmpty {
                    if issues.count < inputs.count {
                        Text("Compatible files can export. Files that still fail these checks will appear as failures in the export report.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(issues, id: \.index) { issue in
                        Text("\(issue.index + 1). \(inputs[issue.index].lastPathComponent) · \(issue.error.localizedDescription)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Button("Recheck Audio") {
                    stopPlayback()
                    review = nil
                    loaded = nil
                    refreshID = UUID()
                }
            } else if input != nil {
                ProgressView("Checking audio selections…").controlSize(.small)
            }
        }
        .task(id: WaveformRequest(url: input, revision: refreshID)) { await load(input) }
        .task(id: ReviewRequest(inputs: inputs, revision: refreshID)) { await inspect(inputs) }
        .task(id: looping) { await followPlayback() }
        .onChange(of: options) { stopPlayback() }
        .onDisappear {
            stopPlayback()
            review = nil
        }
    }

    private struct WaveformRequest: Equatable {
        let url: URL?
        let revision: UUID
    }

    private struct ReviewRequest: Equatable {
        let inputs: [URL]
        let revision: UUID
    }

    private func inspect(_ inputs: [URL]) async {
        guard !inputs.isEmpty else { return }
        let worker = Task.detached(priority: .userInitiated) {
            var sources: [Result<AudioTrimSource, any Error>] = []
            for input in inputs {
                if Task.isCancelled { break }
                sources.append(Result { try AudioTrim.source(input) })
            }
            return sources
        }
        let sources = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        review = AudioTrimReview(inputs: inputs, sources: sources)
    }

    @ViewBuilder
    private func waveformEditor(_ waveform: AudioTrimWaveform) -> some View {
        let duration = waveform.source.duration
        let selection = Result { try AudioTrimSelection.plan(waveform.source, options: options) }
        if inputs.count > 1, let input {
            Text("Showing \(input.lastPathComponent). Times apply to each file.")
                .font(.callout).foregroundStyle(.secondary)
        }
        AudioTrimWaveformView(peaks: waveform.peaks, duration: duration, start: options.start,
                              end: options.end ?? duration, playhead: playhead) { start, end in
            options.start = start
            options.end = end
        }
        HStack {
            Text("0:00")
            Spacer()
            Text(Self.timecode(duration))
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

        SettingRow("Start") {
            AudioTrimTimeField(label: "Selection start", seconds: $options.start)
            Text("seconds or timecode").font(.callout).foregroundStyle(.secondary)
        }
        SettingRow("End") {
            if let end = options.end {
                AudioTrimTimeField(label: "Selection end", seconds: Binding(
                    get: { options.end ?? end }, set: { options.end = $0 }
                ))
                Button("Use End") { options.end = nil }
            } else {
                Text("End of audio").foregroundStyle(.secondary)
                Button("Set Time") { options.end = duration }
            }
        }
        if options.mode == .precise {
            SettingRow("Fade in") {
                AudioTrimTimeField(label: "Fade in duration", seconds: $options.fadeIn)
                Text("seconds").foregroundStyle(.secondary)
            }
            SettingRow("Fade out") {
                AudioTrimTimeField(label: "Fade out duration", seconds: $options.fadeOut)
                Text("seconds").foregroundStyle(.secondary)
            }
        }
        if case .success(let range) = selection {
            let seconds = Double(range.frameCount) / waveform.source.sampleRate
            HStack {
                Button(looping ? "Stop Loop" : "Loop Selection", systemImage: looping ? "stop.fill" : "repeat") {
                    if looping { stopPlayback() }
                    else { startPlayback(range: range, sampleRate: waveform.source.sampleRate) }
                }
                Spacer()
                Text("Selection · \(Self.timecode(seconds))").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        if let previewError { Text(previewError).font(.callout).foregroundStyle(.secondary) }
    }

    private func selectMode(_ mode: AudioTrimMode) {
        options.mode = mode
        if mode == .lossless {
            options.fadeIn = 0
            options.fadeOut = 0
            if let detected = try? loaded?.result.get().source.losslessFormat { options.format = detected }
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 3)))
    }

    private func load(_ url: URL?) async {
        stopPlayback()
        previewError = nil
        guard let url else { loaded = nil; return }
        do {
            let waveform = try await AudioTrim.waveform(url)
            if !Task.isCancelled { loaded = Loaded(url: url, result: .success(waveform)) }
        } catch {
            if !Task.isCancelled { loaded = Loaded(url: url, result: .failure(error)) }
        }
    }

    private func startPlayback(range: AudioTrimSelection, sampleRate: Double) {
        guard let input else { return }
        previewError = nil
        do {
            let audio = try AVAudioPlayer(contentsOf: input)
            let start = Double(range.firstFrame) / sampleRate
            audio.currentTime = start
            audio.volume = range.fadeInFrames == 0 ? 1 : 0
            guard audio.play() else { throw ToolError.invalid("Could not audition this audio file.") }
            player = audio
            playhead = start
            looping = true
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        looping = false
        playhead = nil
    }

    private func followPlayback() async {
        guard looping, let player, let waveform = try? loaded?.result.get(),
              let range = try? AudioTrimSelection.plan(waveform.source, options: options) else { return }
        let rate = waveform.source.sampleRate
        let start = Double(range.firstFrame) / rate
        let end = Double(range.endFrame) / rate
        let fadeIn = Double(range.fadeInFrames) / rate
        let fadeOut = Double(range.fadeOutFrames) / rate
        while !Task.isCancelled, looping {
            if !player.isPlaying || player.currentTime >= end {
                player.currentTime = start
                if !player.play() {
                    stopPlayback()
                    return
                }
            }
            let now = player.currentTime
            var gain = 1.0
            if fadeIn > 0 { gain = min(gain, (now - start) / fadeIn) }
            if fadeOut > 0 { gain = min(gain, (end - now) / fadeOut) }
            player.volume = Float(max(0, gain))
            playhead = now
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return }
        }
    }
}

private struct AudioTrimTimeField: View {
    let label: String
    @Binding var seconds: Double
    @FocusState private var editing: Bool
    @State private var typed: String?

    var body: some View {
        TextField(label, text: Binding {
            if editing, let typed, (Self.parse(typed) ?? -1) == seconds { return typed }
            return seconds >= 0 ? seconds.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) : (typed ?? "")
        } set: { value in
            typed = value
            seconds = Self.parse(value) ?? -1
        })
        .focused($editing)
        .frame(width: 105)
    }

    private static func parse(_ value: String) -> Double? {
        let decimal = Locale.current.decimalSeparator ?? "."
        let fields = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count), let last = fields.last,
              let tail = Double(last.replacingOccurrences(of: decimal, with: ".")), tail.isFinite, tail >= 0 else { return nil }
        if fields.count == 1 { return tail }
        guard tail < 60, let leading = Int(fields[fields.count - 2]), leading >= 0 else { return nil }
        if fields.count == 2 { return Double(leading) * 60 + tail }
        guard leading < 60, let hours = Int(fields[0]), hours >= 0 else { return nil }
        return Double(hours) * 3600 + Double(leading) * 60 + tail
    }
}
