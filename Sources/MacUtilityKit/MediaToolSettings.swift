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
                    Picker("Audio", selection: $draft.options.conversion.audio) {
                        ForEach(VideoConversionAudio.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                if !conversion.requiresFFmpeg || conversion.ffmpegExecutable != nil {
                    executablePicker("FFmpeg", selection: $draft.options.conversion.ffmpegExecutable)
                }
            }
            .padding(.top, 8)
        }
        if conversion.requiresFFmpeg, conversion.ffmpegExecutable == nil {
            Label("These settings require FFmpeg.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            executablePicker("FFmpeg", selection: $draft.options.conversion.ffmpegExecutable)
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

    func extractionControls() -> some View {
        AudioExtractionControls(
            inputs: draft.inputs,
            options: $draft.options.extraction,
            showsAdvanced: $draft.showsAdvanced,
            previewDisabled: session.isRunning,
            preview: { session.startAudioPreview(draft) }
        )
    }
}

private struct AudioExtractionControls: View {
    let inputs: [URL]
    @Binding var options: AudioExtractionOptions
    @Binding var showsAdvanced: Bool
    let previewDisabled: Bool
    let preview: () -> Void
    @State private var tracks: [AudioExtractionTrack] = []
    @State private var trackError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !tracks.isEmpty {
                SettingRow("Audio track") {
                    Picker("Audio track", selection: $options.trackIndex) {
                        ForEach(tracks) { track in Text(track.title).tag(track.index) }
                    }
                    .labelsHidden()
                }
                if inputs.count > 1 {
                    Text("The selected track number applies to each file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let trackError {
                Text(trackError).font(.caption).foregroundStyle(.secondary)
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
            Button("Preview first file", systemImage: "play.rectangle", action: preview)
                .disabled(previewDisabled || tracks.isEmpty)
        }
        .task(id: inputs.first) {
            tracks = []
            trackError = nil
            guard let input = inputs.first else { return }
            do {
                let discovered = try await AudioExtraction.trackList(input)
                guard !Task.isCancelled else { return }
                tracks = discovered
                if discovered.isEmpty { trackError = "The first file has no audio tracks." }
                if !tracks.contains(where: { $0.index == options.trackIndex }) {
                    options.trackIndex = tracks.first?.index ?? 0
                }
            } catch {
                if !Task.isCancelled { trackError = error.localizedDescription }
            }
        }
    }
}

private func executablePicker(_ name: String, selection: Binding<URL?>) -> some View {
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
