import AppKit
import AVFoundation
import SwiftUI
import UtilityCore

struct AudioCleanupControls: View {
    let inputs: [URL]
    @Binding var options: AudioCleanupOptions

    @State private var media: Media?
    @State private var start = 0.0
    @State private var length = 5.0
    @State private var preview: PreviewResult?
    @State private var issue: String?
    @State private var player: AVAudioPlayer?
    @State private var pending: Task<Void, Never>?

    private struct Media {
        let url: URL
        let duration: Double?
        let tracks: [AudioExtractionTrack]
        let issue: String?
    }

    private struct PreviewRequest: Equatable {
        let url: URL
        let options: AudioCleanupOptions
        let start: Double
        let duration: Double
    }

    private struct PreviewResult {
        let request: PreviewRequest
        let sample: AudioCleanupPreview
    }

    var body: some View {
        let url = inputs.first
        let loaded = media?.url == url ? media : nil
        let issue = options.validationIssue
        let request = loaded?.duration.flatMap { duration in
            let segment = min(length, duration - start)
            return segment >= 0.1 && issue == nil && !((loaded?.tracks ?? []).isEmpty)
                ? url.map { PreviewRequest(url: $0, options: options, start: start, duration: segment) } : nil
        }
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("FFmpeg") {
                Button(options.executable == nil ? "Choose FFmpeg…" : "Change…") { chooseFFmpeg() }
                if let executable = options.executable {
                    Text(executable.lastPathComponent).lineLimit(1).help(executable.path)
                }
            }
            if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            SettingRow("Output") {
                Picker("Output", selection: $options.output) {
                    ForEach(AudioCleanupOutput.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            if options.output == .mkv {
                Text("Copies the original picture stream and replaces the soundtrack with the cleaned track.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let loaded, !loaded.tracks.isEmpty {
                SettingRow("Audio track") {
                    Picker("Audio track", selection: $options.trackIndex) {
                        ForEach(loaded.tracks) { Text($0.title).tag($0.index) }
                    }
                    .labelsHidden()
                }
            }
            SettingRow("Profile") {
                Picker("Profile", selection: $options.profile) {
                    ForEach(AudioCleanupProfile.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            SettingRow("Noise reduction") {
                Slider(value: $options.reductionDB, in: 0...24, step: 1)
                    .accessibilityLabel("Noise reduction")
                Text("\(Int(options.reductionDB)) dB")
                    .font(.callout.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
            }
            SettingRow("Hum removal") {
                Picker("Hum removal", selection: $options.hum) {
                    ForEach(AudioCleanupHum.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            if let duration = loaded?.duration, duration >= 0.1 && !((loaded?.tracks ?? []).isEmpty) {
                segmentControls(duration, request: request)
            }
            if let detail = issue ?? loaded?.issue {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: url) { await load(url) }
        .onChange(of: request) { clearPreview() }
        .onDisappear { clearPreview() }
    }

    private func segmentControls(_ duration: Double, request: PreviewRequest?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if inputs.count > 1, let input = inputs.first {
                Text("Previewing \(input.lastPathComponent). The selected track number applies to each file.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingRow("Preview start") {
                Slider(value: $start, in: 0...max(0.01, duration - 0.1))
                    .accessibilityLabel("Preview start")
                Text(time(start)).font(.callout.monospacedDigit())
            }
            SettingRow("Preview length") {
                Picker("Preview length", selection: $length) {
                    ForEach([2.0, 5.0, 8.0, 12.0], id: \.self) { value in
                        Text("\(Int(value)) s").tag(value)
                    }
                }
                .labelsHidden()
            }
            if let request, let preview, preview.request == request {
                HStack {
                    Button("Original", systemImage: "speaker.wave.2") { play(preview.sample, cleaned: false) }
                    Button("Cleaned", systemImage: "speaker.wave.2") { play(preview.sample, cleaned: true) }
                    Button("Stop", systemImage: "stop") { stop() }.disabled(player == nil)
                }
                Text("Playback levels matched by RMS · \(time(preview.sample.duration))")
                    .font(.callout).foregroundStyle(.secondary)
                if preview.sample.isNearClipping {
                    Label("Cleaned audio peaks near clipping.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if pending != nil {
                ProgressView("Preparing comparison…").controlSize(.small)
            } else {
                Button("Prepare A/B Preview", systemImage: "waveform") {
                    if let request { prepare(request) }
                }
                .disabled(request == nil)
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 1)))
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        if panel.runModal() == .OK { options.executable = panel.url }
    }

    private func load(_ url: URL?) async {
        clearPreview()
        guard let url else { media = nil; return }
        do {
            let tracks = try await AudioExtraction.trackList(url)
            let duration = try await AudioCleanup.duration(url)
            guard !Task.isCancelled else { return }
            start = 0
            if !tracks.contains(where: { $0.index == options.trackIndex }) {
                options.trackIndex = 0
            }
            media = Media(url: url, duration: duration, tracks: tracks,
                          issue: tracks.isEmpty ? "This file has no audio track." : nil)
        } catch {
            if !Task.isCancelled {
                media = Media(url: url, duration: nil, tracks: [], issue: error.localizedDescription)
            }
        }
    }

    private func prepare(_ request: PreviewRequest) {
        clearPreview()
        pending = Task {
            do {
                let sample = try await AudioCleanup.preview(request.url, options: request.options,
                                                            start: request.start, duration: request.duration)
                guard !Task.isCancelled else { return }
                preview = PreviewResult(request: request, sample: sample)
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription
            }
            pending = nil
        }
    }

    private func play(_ sample: AudioCleanupPreview, cleaned: Bool) {
        issue = nil
        let current = player?.isPlaying == true ? (player?.currentTime ?? 0) : 0
        stop()
        do {
            let audio = try AVAudioPlayer(data: cleaned ? sample.cleaned : sample.original)
            audio.currentTime = min(current, audio.duration)
            audio.volume = cleaned ? sample.cleanedVolume : sample.originalVolume
            guard audio.play() else { throw ToolError.invalid("Could not play this preview segment.") }
            player = audio
        } catch {
            issue = error.localizedDescription
        }
    }

    private func stop() {
        player?.stop()
        player = nil
    }

    private func clearPreview() {
        pending?.cancel()
        pending = nil
        preview = nil
        issue = nil
        stop()
    }
}
