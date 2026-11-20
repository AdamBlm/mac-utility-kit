import AppKit
import SwiftUI
import UtilityCore

extension ToolWorkspace {
    @ViewBuilder
    func conversionControls() -> some View {
        let conversion = draft.options.conversion
        SettingRow("Output format") {
            Picker("Output format", selection: Binding(
                get: { draft.options.conversion.format },
                set: { format in
                    draft.options.conversion.format = format
                    if !format.supportedCodecs.contains(draft.options.conversion.codec),
                       let codec = format.supportedCodecs.first {
                        draft.options.conversion.codec = codec
                    }
                    if let bitrate = draft.options.conversion.audioKbps, !format.audioBitrateRange.contains(bitrate) {
                        draft.options.conversion.audioKbps = nil
                    }
                }
            )) {
                ForEach(VideoConversionFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        SettingRow("Method") {
            Picker("Method", selection: Binding(
                get: { draft.options.conversion.mode },
                set: { mode in
                    draft.options.conversion.mode = mode
                    if mode == .passthrough {
                        draft.options.conversion.maximumHeight = nil
                        draft.options.conversion.frameRate = nil
                        draft.options.conversion.audioKbps = nil
                    }
                }
            )) {
                ForEach(VideoConversionMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        if conversion.mode == .transcode {
            SettingRow("Codec") {
                Picker("Codec", selection: $draft.options.conversion.codec) {
                    ForEach(Array(conversion.format.supportedCodecs), id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
        DisclosureGroup("Advanced", isExpanded: $draft.showsAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                if conversion.mode == .transcode {
                    SettingRow("Resolution limit") {
                        Picker("Resolution limit", selection: $draft.options.conversion.maximumHeight) {
                            Text("Source").tag(Int?.none)
                            ForEach([480, 720, 1080, 1440, 2160], id: \.self) { height in
                                Text("\(height)p").tag(Optional(height))
                            }
                        }
                        .labelsHidden()
                    }
                    SettingRow("Frame rate") {
                        Picker("Frame rate", selection: $draft.options.conversion.frameRate) {
                            Text("Source").tag(Int?.none)
                            ForEach([24, 25, 30, 50, 60], id: \.self) { rate in
                                Text("\(rate) fps").tag(Optional(rate))
                            }
                        }
                        .labelsHidden()
                    }
                }
                SettingRow("Audio") {
                    Picker("Audio", selection: Binding(
                        get: { draft.options.conversion.audio },
                        set: { audio in
                            draft.options.conversion.audio = audio
                            if audio == .remove { draft.options.conversion.audioKbps = nil }
                        }
                    )) {
                        ForEach(VideoConversionAudio.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                if conversion.mode == .transcode, conversion.audio == .keep {
                    SettingRow("Audio bitrate") {
                        Picker("Audio bitrate per track", selection: $draft.options.conversion.audioKbps) {
                            Text("Automatic").tag(Int?.none)
                            let bitrates = [32, 48, 64, 96, 128, 160, 192, 256, 320]
                            ForEach(bitrates.filter(conversion.format.audioBitrateRange.contains), id: \.self) { kbps in
                                Text("\(kbps) kb/s per track").tag(Optional(kbps))
                            }
                        }
                        .labelsHidden()
                        .help("Custom bitrate requires FFmpeg. \(conversion.format.title) targets range from \(conversion.format.audioBitrateRange.lowerBound) to \(conversion.format.audioBitrateRange.upperBound) kb/s per track. The achieved rate depends on the source audio.")
                    }
                }
                if !conversion.requiresFFmpeg || conversion.ffmpegExecutable != nil {
                    executablePicker("FFmpeg", selection: $draft.options.conversion.ffmpegExecutable)
                }
            }
            .padding(.top, 8)
        }
        if conversion.requiresFFmpeg, conversion.ffmpegExecutable == nil {
            executablePicker("FFmpeg", selection: $draft.options.conversion.ffmpegExecutable)
        }
        if let issue = conversion.validationIssue {
            Label(issue, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func inspectionControls() -> some View {
        Text("Shows a summary and saves a JSON report for each source file.")
            .font(.callout).foregroundStyle(.secondary)
        DisclosureGroup("Advanced", isExpanded: $draft.showsAdvanced) {
            executablePicker("ffprobe", selection: $draft.options.inspection.ffprobeExecutable)
                .padding(.top, 8)
        }
    }

    func extractionControls(review: Binding<AudioExtractionReview>) -> some View {
        AudioExtractionControls(
            inputs: draft.inputs,
            options: $draft.options.extraction,
            review: review,
            showsAdvanced: $draft.showsAdvanced,
            previewDisabled: session.isRunning,
            preview: { session.startAudioPreview(draft, input: $0) }
        )
    }
}

struct AudioExtractionReview {
    var inputs: [URL] = []
    var tracks: [URL: [AudioExtractionTrack]] = [:]
    var errors: [URL: String] = [:]

    func permitsExport(options: AudioExtractionOptions) -> Bool {
        inputs.allSatisfy { tracks[$0] != nil || errors[$0] != nil }
            && tracks.values.contains { (try? AudioExtraction.selectedTrack(in: $0, options: options)) != nil }
    }
}

private struct AudioExtractionControls: View {
    let inputs: [URL]
    @Binding var options: AudioExtractionOptions
    @Binding var review: AudioExtractionReview
    @Binding var showsAdvanced: Bool
    let previewDisabled: Bool
    let preview: (URL) -> Void
    @State private var languages: [String] = []
    @State private var chosenPreview: URL?
    @State private var revision = 0

    private struct Inspection: Equatable {
        let inputs: [URL]
        let revision: Int
    }

    private var tracksBySource: [URL: [AudioExtractionTrack]] { review.inputs == inputs ? review.tracks : [:] }

    private var previewInput: URL? {
        if let chosenPreview, inputs.contains(chosenPreview) { return chosenPreview }
        return inputs.first
    }

    private var tracks: [AudioExtractionTrack] {
        previewInput.flatMap { tracksBySource[$0] } ?? []
    }

    private func languageTitle(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !languages.isEmpty || options.trackLanguage != nil {
                SettingRow("Select by") {
                    Picker("Select by", selection: $options.trackLanguage) {
                        Text("Track number").tag(nil as String?)
                        if let language = options.trackLanguage, !languages.contains(language) {
                            Text(languageTitle(language)).tag(Optional(language))
                        }
                        ForEach(languages, id: \.self) { language in
                            Text(languageTitle(language)).tag(Optional(language))
                        }
                    }
                    .labelsHidden()
                }
            }
            if options.trackLanguage == nil, !tracks.isEmpty {
                SettingRow("Audio track") {
                    Picker("Audio track", selection: $options.trackIndex) {
                        if !tracks.contains(where: { $0.index == options.trackIndex }) {
                            Text("Track \(options.trackIndex + 1) · Unavailable").tag(options.trackIndex)
                        }
                        ForEach(tracks) { track in Text(track.title).tag(track.index) }
                    }
                    .labelsHidden()
                }
                if inputs.count > 1 {
                    Text("The track number applies to every file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingRow("Output format") {
                Picker("Output format", selection: Binding(
                    get: { options.format },
                    set: { format in
                        options.format = format
                        if !format.supportsPassthrough { options.passthrough = false }
                    }
                )) {
                    ForEach(AudioOutputFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if options.format.supportsPassthrough {
                Toggle("Copy audio without re-encoding", isOn: $options.passthrough)
            }
            if !options.passthrough, options.format == .m4a || options.format == .mp3 {
                SettingRow("Quality") {
                    Picker("Quality", selection: $options.quality) {
                        ForEach(AudioExtractionQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                if !options.format.requiresFFmpeg || options.ffmpegExecutable != nil {
                    executablePicker("FFmpeg", selection: $options.ffmpegExecutable).padding(.top, 8)
                }
            }
            if options.format.requiresFFmpeg, options.ffmpegExecutable == nil {
                executablePicker("FFmpeg", selection: $options.ffmpegExecutable)
            }
            if let issue = options.validationIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
            if let previewInput {
                if inputs.count > 1 {
                    SettingRow("Preview source") {
                        Picker("Preview source", selection: Binding(
                            get: { previewInput },
                            set: { chosenPreview = $0 }
                        )) {
                            ForEach(Array(inputs.enumerated()), id: \.offset) { index, input in
                                Text("\(index + 1). \(input.lastPathComponent)").tag(input)
                            }
                        }
                        .labelsHidden()
                    }
                }
                Button("Preview track", systemImage: "play.rectangle") { preview(previewInput) }
                    .disabled(previewDisabled || (try? AudioExtraction.selectedTrack(in: tracks, options: options, forPreview: true)) == nil)
                Button("Recheck Tracks", systemImage: "arrow.clockwise") {
                    review = AudioExtractionReview()
                    languages = []
                    revision += 1
                }
                if review.inputs != inputs || !inputs.allSatisfy({ review.tracks[$0] != nil || review.errors[$0] != nil }) {
                    ProgressView("Reading audio tracks…").controlSize(.small)
                } else if options.validationIssue == nil {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { index, input in
                        if let issue = trackIssue(input) {
                            let prefix = inputs.count > 1 ? "\(index + 1). \(input.lastPathComponent) · " : ""
                            Text(prefix + issue).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if inputs.contains(where: { trackIssue($0) != nil }), review.permitsExport(options: options) {
                        Text("Files with unavailable tracks will be skipped.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: Inspection(inputs: inputs, revision: revision)) { [request = Inspection(inputs: inputs, revision: revision)] in
            guard !Task.isCancelled, revision == request.revision else { return }
            review = AudioExtractionReview(inputs: request.inputs)
            languages = []
            var discoveredLanguages = Set<String>()
            for input in request.inputs {
                do {
                    let discovered = try await AudioExtraction.trackList(input)
                    guard !Task.isCancelled, revision == request.revision else { return }
                    review.tracks[input] = discovered
                    discoveredLanguages.formUnion(discovered.compactMap(\.languageCode))
                } catch {
                    guard !Task.isCancelled, revision == request.revision else { return }
                    review.errors[input] = error.localizedDescription
                }
            }
            languages = discoveredLanguages.sorted {
                languageTitle($0).localizedStandardCompare(languageTitle($1)) == .orderedAscending
            }
        }
        .onDisappear { review = AudioExtractionReview() }
    }

    private func trackIssue(_ input: URL) -> String? {
        if let error = review.errors[input] { return error }
        guard let tracks = tracksBySource[input] else { return nil }
        do {
            _ = try AudioExtraction.selectedTrack(in: tracks, options: options)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

func executablePicker(_ name: String, selection: Binding<URL?>) -> some View {
    HStack {
        if let current = selection.wrappedValue {
            Label(current.lastPathComponent, systemImage: "gearshape")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Use macOS") { selection.wrappedValue = nil }
        } else {
            Text("macOS engine").foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        Button("Choose \(name)…") {
            let panel = NSOpenPanel()
            if panel.runModal() == .OK { selection.wrappedValue = panel.url }
        }
    }
    .font(.callout)
}
