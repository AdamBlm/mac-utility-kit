import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ReplaceAudioReview {
    var inputs: [URL] = []
    var originals: [URL: Result<[AudioExtractionTrack], Error>] = [:]
    var replacementInput: URL?
    var replacementTracks: [AudioExtractionTrack]?

    func hasReplacement(options: ReplaceAudioOptions) -> Bool {
        guard let source = options.source, replacementInput == source else { return false }
        return replacementTracks?.contains(where: { $0.index == options.sourceTrackIndex }) == true
    }

    func permitsExport(inputs: [URL], options: ReplaceAudioOptions) -> Bool {
        guard hasReplacement(options: options) else { return false }
        guard options.mode == .mix else { return true }
        return self.inputs == inputs && inputs.contains { file in
            (try? originals[file]?.get())?.contains(where: { $0.index == options.originalTracks[file, default: 0] }) == true
        }
    }
}

struct ReplaceAudioControls: View {
    let inputs: [URL]
    @Binding var options: ReplaceAudioOptions
    @Binding var review: ReplaceAudioReview

    @State private var replacementIssue: String?
    @State private var previewInput: URL?
    @State private var request: ListeningRequest?
    @State private var player: AVAudioPlayer?
    @State private var peak: ReplaceAudio.Sample?
    @State private var previewIssue: String?
    @State private var isDroppingAudio = false
    @State private var trackRevision = 0

    private struct TrackRequest<Source: Equatable>: Equatable {
        let source: Source
        let revision: Int
    }

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

    private var originalTracks: [URL: [AudioExtractionTrack]] {
        review.inputs == inputs ? review.originals.compactMapValues { try? $0.get() } : [:]
    }
    private var replacementTracks: [AudioExtractionTrack]? {
        review.replacementInput == options.source ? review.replacementTracks : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            sourceControls
            mixControls
            previewControls
        }
        .task(id: TrackRequest(source: options.source, revision: trackRevision)) { [source = options.source, revision = trackRevision] in
            await inspectReplacement(source, revision: revision)
        }
        .task(id: TrackRequest(source: inputs, revision: trackRevision)) { [revision = trackRevision] in
            await inspectOriginals(revision: revision)
        }
        .task(id: request) {
            if let request { await listen(to: request) }
        }
        .onChange(of: options) { clearPreview() }
        .onChange(of: activeInput) { clearPreview() }
        .onDisappear {
            clearPreview()
            review = ReplaceAudioReview()
        }
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
                if options.source != nil || !inputs.isEmpty {
                    Button("Recheck Audio Tracks", systemImage: "arrow.clockwise") {
                        clearPreview()
                        review = ReplaceAudioReview()
                        replacementIssue = nil
                        options.originalTracks = [:]
                        options.sourceTrackIndex = 0
                        trackRevision += 1
                    }
                    .labelStyle(.iconOnly)
                    .help("Refresh audio tracks and reset track selections.")
                }
            }
            if let replacementTracks, !replacementTracks.isEmpty {
                SettingRow("New track") {
                    Picker("Replacement audio track", selection: $options.sourceTrackIndex) {
                        ForEach(replacementTracks) { Text($0.title).tag($0.index) }
                    }
                    .labelsHidden()
                }
                if !review.hasReplacement(options: options) {
                    Text("Choose an available replacement audio track.").font(.callout).foregroundStyle(.secondary)
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
                if review.inputs == inputs, inputs.contains(where: { originalTracks[$0]?.isEmpty == true }),
                   review.permitsExport(inputs: inputs, options: options) {
                    Text("Mix requires original audio. Videos without it will be reported as failed.")
                        .font(.callout).foregroundStyle(.secondary)
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
                    .disabled(!isActive && !canListen(variant))
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

    private func canListen(_ variant: ReplaceAudio.Preview) -> Bool {
        guard let input = activeInput else { return false }
        let selected = originalTracks[input]?.contains { $0.index == options.originalTracks[input, default: 0] } == true
        if variant == .original { return selected }
        return review.hasReplacement(options: options) && (options.mode != .mix || selected)
    }

    @ViewBuilder
    private func originalPicker(for input: URL) -> some View {
        if review.inputs == inputs, case .failure(let error) = review.originals[input] {
            Text("\(input.lastPathComponent) · \(error.localizedDescription)")
                .font(.callout).foregroundStyle(.secondary)
        } else if let tracks = originalTracks[input] {
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
                if !tracks.contains(where: { $0.index == options.originalTracks[input, default: 0] }) {
                    Text("Choose an available original audio track for \(input.lastPathComponent).")
                        .font(.callout).foregroundStyle(.secondary)
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
        review.replacementInput = nil
        review.replacementTracks = nil
        replacementIssue = nil
        options.sourceTrackIndex = 0
        options.source = url
    }

    private func inspectReplacement(_ url: URL?, revision: Int) async {
        guard !Task.isCancelled, trackRevision == revision else { return }
        review.replacementInput = url
        review.replacementTracks = nil
        replacementIssue = nil
        guard let url else { return }
        do {
            let tracks = try await AudioExtraction.trackList(url)
            try Task.checkCancellation()
            guard options.source == url, review.replacementInput == url, trackRevision == revision else { return }
            review.replacementTracks = tracks
            if tracks.isEmpty { replacementIssue = "This file has no readable audio tracks." }
        } catch {
            if !Task.isCancelled, trackRevision == revision, options.source == url {
                replacementIssue = error.localizedDescription
            }
        }
    }

    private func inspectOriginals(revision: Int) async {
        guard !Task.isCancelled, trackRevision == revision else { return }
        review.inputs = []
        review.originals = [:]
        var updated: [URL: Result<[AudioExtractionTrack], Error>] = [:]
        for input in inputs {
            do { updated[input] = .success(try await AudioExtraction.trackList(input)) }
            catch { updated[input] = .failure(error) }
            guard !Task.isCancelled, trackRevision == revision else { return }
        }
        review.originals = updated
        review.inputs = inputs
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
