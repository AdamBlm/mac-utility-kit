import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ReplaceAudioControls: View {
    let inputs: [URL]
    @Binding var options: ReplaceAudioOptions

    @State private var originalTracks: [URL: [AudioExtractionTrack]] = [:]
    @State private var replacementTracks: [AudioExtractionTrack]?
    @State private var replacementIssue: String?
    @State private var previewInput: URL?
    @State private var request: ListeningRequest?
    @State private var player: AVAudioPlayer?
    @State private var peak: ReplaceAudio.Sample?
    @State private var previewIssue: String?
    @State private var isDroppingAudio = false

    private struct ListeningRequest: Equatable {
        let id = UUID()
        let input: URL
        let variant: ReplaceAudio.Preview
        let options: ReplaceAudioOptions
    }

    private var activeInput: URL? {
        if let previewInput, inputs.contains(previewInput) { return previewInput }
        return inputs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            sourceControls
            mixControls
            previewControls
        }
        .task(id: options.source) { await inspectReplacement(options.source) }
        .task(id: inputs) { await inspectOriginals() }
        .task(id: request) {
            if let request { await listen(to: request) }
        }
        .onChange(of: options) { clearPreview() }
        .onChange(of: activeInput) { clearPreview() }
        .onDisappear { clearPreview() }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("Choose Audio…", systemImage: "waveform") { chooseReplacement() }
                Text(options.source?.lastPathComponent ?? "or drop an audio file here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if options.source != nil {
                    Button("Remove Audio File", systemImage: "xmark.circle") { setReplacement(nil) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            if let replacementTracks, !replacementTracks.isEmpty {
                SettingRow("New track") {
                    Picker("Replacement audio track", selection: $options.sourceTrackIndex) {
                        ForEach(replacementTracks) { Text($0.title).tag($0.index) }
                    }
                    .labelsHidden()
                }
            } else if let replacementIssue {
                Text(replacementIssue).font(.callout).foregroundStyle(.secondary)
            } else if options.source != nil {
                ProgressView("Reading tracks…").controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(isDroppingAudio ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.first(where: { $0.isFileURL && UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }) else {
                return false
            }
            setReplacement(file)
            return true
        } isTargeted: { isDroppingAudio = $0 }
    }

    private var mixControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow("Soundtrack") {
                Picker("Soundtrack mode", selection: $options.mode) {
                    ForEach(ReplaceAudioOptions.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            SettingRow("Duration") {
                Picker("Duration policy", selection: $options.durationPolicy) {
                    ForEach(ReplaceAudioOptions.DurationPolicy.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            SettingRow("Audio offset") {
                HStack(spacing: 6) {
                    TextField("Audio offset in seconds", value: $options.offsetSeconds, format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                    Text("seconds").font(.callout).foregroundStyle(.secondary)
                }
                .help("Positive values delay the new track. Negative values skip its beginning.")
            }
            volume("New audio", value: $options.newVolume)
            if options.mode == .mix {
                volume("Original audio", value: $options.originalVolume)
                ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                    originalPicker(for: input)
                }
            } else if let activeInput, let tracks = originalTracks[activeInput], tracks.count > 1 {
                originalPicker(for: activeInput)
            }
        }
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            if inputs.count > 1 {
                SettingRow("Preview file") {
                    Picker("Preview file", selection: Binding(get: { activeInput }, set: { previewInput = $0 })) {
                        ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                            Text(input.lastPathComponent).tag(Optional(input))
                        }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                ForEach(ReplaceAudio.Preview.allCases) { variant in
                    let isActive = request?.variant == variant
                    Button(isActive ? "Stop \(variant.rawValue)" : "Play \(variant.rawValue)",
                           systemImage: isActive ? "stop.circle" : "play.circle") {
                        if isActive { stop() } else { start(variant) }
                    }
                    .disabled(activeInput == nil || (variant == .original
                              ? activeInput.flatMap { originalTracks[$0] }?.isEmpty != false
                              : replacementTracks?.isEmpty != false))
                }
                if request != nil && player == nil {
                    ProgressView().controlSize(.small)
                }
            }
            if let peak {
                let location = peak.startSeconds.formatted(.number.precision(.fractionLength(1)))
                let level = peak.peak > 0 ? "\((20 * log10(Double(peak.peak))).formatted(.number.precision(.fractionLength(1)))) dBFS" : "Silence"
                Label("Result peak \(level) · sample starts at \(location) s",
                      systemImage: peak.isNearClipping ? "exclamationmark.triangle" : "waveform")
                    .font(.callout)
                    .foregroundStyle(peak.isNearClipping ? Color.orange : Color.secondary)
                if peak.isNearClipping {
                    Text("The preview is near full scale. Lower a track level to reduce clipping.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let previewIssue {
                Text(previewIssue).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func originalPicker(for input: URL) -> some View {
        if let tracks = originalTracks[input] {
            if tracks.isEmpty {
                Text("\(input.lastPathComponent) has no original audio to mix.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                SettingRow(inputs.count == 1 ? "Original track" : input.lastPathComponent) {
                    Picker("Original track in \(input.lastPathComponent)", selection: Binding(
                        get: { options.originalTracks[input, default: 0] },
                        set: { options.originalTracks[input] = $0 }
                    )) {
                        ForEach(tracks) { Text($0.title).tag($0.index) }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private func volume(_ label: String, value: Binding<Double>) -> some View {
        SettingRow(label) {
            Slider(value: value, in: 0...1, step: 0.01) { Text(label) }
                .labelsHidden()
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .font(.callout)
                .frame(width: 43, alignment: .trailing)
        }
    }

    private func chooseReplacement() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.audio, .movie]
        if picker.runModal() == .OK { setReplacement(picker.url) }
    }

    private func setReplacement(_ url: URL?) {
        guard options.source != url else { return }
        replacementTracks = nil
        replacementIssue = nil
        options.sourceTrackIndex = 0
        options.source = url
    }

    private func inspectReplacement(_ url: URL?) async {
        replacementTracks = nil
        replacementIssue = nil
        guard let url else { return }
        do {
            let tracks = try await AudioExtraction.trackList(url)
            try Task.checkCancellation()
            replacementTracks = tracks
            if tracks.isEmpty { replacementIssue = "This file has no readable audio tracks." }
        } catch {
            if !Task.isCancelled { replacementIssue = error.localizedDescription }
        }
    }

    private func inspectOriginals() async {
        var updated: [URL: [AudioExtractionTrack]] = [:]
        for input in inputs {
            let tracks = (try? await AudioExtraction.trackList(input)) ?? []
            guard !Task.isCancelled else { return }
            updated[input] = tracks
        }
        originalTracks = updated
    }

    private func start(_ variant: ReplaceAudio.Preview) {
        guard let input = activeInput else { return }
        stop()
        previewIssue = nil
        request = ListeningRequest(input: input, variant: variant, options: options)
    }

    private func listen(to request: ListeningRequest) async {
        do {
            let sample = try await ReplaceAudio.sample(request.input, options: request.options, preview: request.variant)
            try Task.checkCancellation()
            guard self.request == request else { return }
            let audio = try AVAudioPlayer(data: sample.data)
            guard audio.duration.isFinite, audio.duration > 0, audio.play() else {
                throw ToolError.invalid("Could not play the preview sample.")
            }
            player = audio
            if request.variant == .result { peak = sample }
            try await Task.sleep(for: .seconds(audio.duration))
            if self.request == request { stop() }
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            previewIssue = error.localizedDescription
            stop()
        }
    }

    private func clearPreview() {
        stop()
        peak = nil
        previewIssue = nil
    }

    private func stop() {
        player?.stop()
        player = nil
        request = nil
    }
}
