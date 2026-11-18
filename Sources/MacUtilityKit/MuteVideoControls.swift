import AVFoundation
import SwiftUI
import UtilityCore

struct MuteVideoControls: View {
    let inputs: [URL]
    @Binding var options: MuteVideoOptions
    @State private var streams: [URL: [MuteVideoStream]] = [:]
    @State private var issues: [URL: String] = [:]
    @State private var preview: AudioPreview?
    @State private var player: AVAudioPlayer?
    @State private var previewIssue: String?

    private struct AudioPreview: Equatable {
        let input: URL
        let audioIndex: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Remove") {
                Picker("Remove audio", selection: $options.removal) {
                    ForEach(MuteVideoOptions.Removal.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .labelsHidden()
            }
            SettingRow("Container") {
                Picker("Output container", selection: $options.container) {
                    ForEach(MuteVideoOptions.Container.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .labelsHidden()
            }
            if let previewIssue { Text(previewIssue).font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(input.lastPathComponent)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let issue = issues[input] {
                        Text(issue).font(.callout).foregroundStyle(.secondary)
                    } else if let tracks = streams[input] {
                        streamPreview(tracks, for: input)
                    } else {
                        ProgressView("Reading streams…").controlSize(.small)
                    }
                }
            }
        }
        .task(id: preview) {
            guard let preview else { return }
            await play(preview)
        }
        .onChange(of: inputs) {
            if let preview, !inputs.contains(preview.input) { stopPreview() }
        }
        .onDisappear { stopPreview() }
        .task(id: inputs) {
            streams = [:]
            issues = [:]
            for input in inputs {
                do {
                    let result = try await MuteVideo.inspect(input)
                    try Task.checkCancellation()
                    streams[input] = result
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    issues[input] = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func streamPreview(_ tracks: [MuteVideoStream], for input: URL) -> some View {
        if tracks.allSatisfy({ !$0.isAudio }) {
            Text("This video already has no audio tracks.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if options.removal == .selected, !tracks.contains(where: { options.removes($0, from: input) }) {
            Text("Select audio tracks to remove.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if case .failure(let error) = Result(catching: { try MuteVideo.outputExtension(input, options: options) }) {
            Text(error.localizedDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(tracks) { track in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(track.kind) \(track.id)").font(.callout)
                    let detail = streamDetail(track)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let audioIndex = track.audioIndex {
                    let sample = AudioPreview(input: input, audioIndex: audioIndex)
                    Button(preview == sample ? "Stop Preview" : "Preview Audio",
                           systemImage: preview == sample ? "stop.circle" : "play.circle") {
                        if preview == sample {
                            stopPreview()
                        } else {
                            stopPreview()
                            previewIssue = nil
                            preview = sample
                        }
                    }
                    .labelStyle(.iconOnly)
                    .help("Listen to five seconds of this track")
                }
                if options.removal == .selected, track.isAudio {
                    Toggle("Remove", isOn: binding(for: track, input: input))
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Remove audio track \(track.id)")
                } else {
                    Text(options.removes(track, from: input) ? "Remove" : "Keep")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func play(_ request: AudioPreview) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacUtilityKit-MutePreview-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localFile = directory.appendingPathComponent("track.m4a")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var audio = AudioExtractionOptions()
            audio.trackIndex = request.audioIndex
            try await AudioExtraction.preview(request.input, to: localFile, options: audio)
            try Task.checkCancellation()
            let sample = try AVAudioPlayer(contentsOf: localFile)
            guard preview == request else { return }
            guard sample.duration.isFinite, sample.duration > 0, sample.play() else {
                throw ToolError.invalid("Could not play this audio track.")
            }
            player = sample
            try await Task.sleep(for: .seconds(sample.duration))
            if preview == request { stopPreview() }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, preview == request else { return }
            previewIssue = error.localizedDescription
            stopPreview()
        }
    }

    private func stopPreview() {
        player?.stop()
        player = nil
        preview = nil
    }

    private func binding(for track: MuteVideoStream, input: URL) -> Binding<Bool> {
        Binding {
            options.removes(track, from: input)
        } set: { remove in
            if remove {
                options.removedTrackIDs[input, default: []].insert(track.id)
            } else {
                options.removedTrackIDs[input, default: []].remove(track.id)
            }
        }
    }

    private func streamDetail(_ track: MuteVideoStream) -> String {
        var detail = track.codecs
        if let language = track.language, language != "und" { detail.append(language) }
        if let channels = track.channels { detail.append(channels == 1 ? "Mono" : "\(channels) channels") }
        return detail.joined(separator: " · ")
    }
}
