import AppKit
import SwiftUI
import UtilityCore

struct CompressionReview {
    struct Request: Equatable {
        let inputs: [URL]
        let executable: URL?
        let format: VideoFormat
        let codec: VideoCodec
        let preset: VideoQuality
        let advanced: VideoCompressionOptions

        init(inputs: [URL], options: ToolOptions) {
            self.inputs = inputs
            executable = options.ffmpegExecutable
            format = options.videoFormat
            codec = options.videoCodec
            preset = options.videoQuality
            advanced = options.videoCompression
        }
    }

    let request: Request
    let supportsFirstInput: Bool
    let supportsAnyInput: Bool
}

struct VideoCompressionControls: View {
    let inputs: [URL]
    @Binding var options: ToolOptions
    @Binding var advancedExpanded: Bool
    @Binding var review: CompressionReview?
    let running: Bool
    let sample: VideoSample?
    let onSample: () -> Void

    @State private var capabilities: (engine: URL, value: VideoCompressionCapabilities)?
    @State private var engineIssue: String?
    @State private var inputNotes: [String] = []
    @State private var sampleRequest: CompressionReview.Request?

    private var selectedCapabilities: VideoCompressionCapabilities? {
        if let executable = options.ffmpegExecutable {
            return capabilities?.engine == executable ? capabilities?.value : nil
        }
        return .macOS
    }

    private var request: CompressionReview.Request { .init(inputs: inputs, options: options) }
    private var availableFormats: [VideoFormat] {
        selectedCapabilities?.formats ?? []
    }

    private var availableCodecs: [VideoCodec] {
        VideoCodec.allCases.filter { selectedCapabilities?.supports(options.videoFormat, codec: $0) == true }
    }

    private var availableRates: [VideoCompressionOptions.RateControl] {
        VideoCompressionOptions.RateControl.allCases.filter { options.ffmpegExecutable != nil || $0 != .constantQuality }
    }

    var body: some View {
        SettingRow("Output format") {
            Picker("Output format", selection: $options.videoFormat) {
                if !availableFormats.contains(options.videoFormat) { Text(options.videoFormat.rawValue.uppercased()).tag(options.videoFormat) }
                ForEach(availableFormats, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .labelsHidden()
            .disabled(availableFormats.isEmpty)
        }
        SettingRow("Codec") {
            Picker("Codec", selection: $options.videoCodec) {
                if !availableCodecs.contains(options.videoCodec) { Text(options.videoCodec.rawValue).tag(options.videoCodec) }
                ForEach(availableCodecs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .disabled(availableCodecs.isEmpty)
        }
        if options.videoCompression.rateControl == .preset {
            SettingRow("Quality preset") {
                Picker("Quality preset", selection: $options.videoQuality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
        }

        DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                SettingRow("Encoder") {
                    Text(options.ffmpegExecutable == nil ? "macOS (VideoToolbox)" : "FFmpeg (software)")
                        .foregroundStyle(.secondary)
                    if options.ffmpegExecutable != nil {
                        Button("Use macOS") { selectEngine(nil) }
                    } else if let installedFFmpeg {
                        Button("Use Installed FFmpeg") { selectEngine(installedFFmpeg) }
                    }
                    Button("Choose FFmpeg…", action: chooseFFmpeg)
                }
                if options.videoFormat == .webm {
                    Text("WebM uses Opus audio with standard mono, stereo, or surround layouts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingRow("Rate control") {
                    Picker("Rate control", selection: $options.videoCompression.rateControl) {
                        ForEach(availableRates, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                if options.videoCompression.rateControl == .averageBitrate {
                    SettingRow("Video bitrate") {
                        VideoBitrateField(value: $options.videoCompression.videoKbps)
                    }
                } else if options.videoCompression.rateControl == .constantQuality {
                    SettingRow("Constant quality") {
                        Slider(value: Binding(get: { Double(options.videoCompression.quality) },
                                              set: { options.videoCompression.quality = Int($0) }),
                               in: 12...45, step: 1) { Text("Constant quality") }
                            .labelsHidden()
                        Text("\(options.videoCompression.quality) RF").monospacedDigit()
                    }
                    Text("Lower RF preserves more detail and usually produces a larger file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingRow("Longest edge") {
                    Picker("Longest-edge limit", selection: $options.videoCompression.maximumEdge) {
                        Text("Keep source resolution").tag(Int?.none)
                        ForEach([640, 854, 1_280, 1_920, 2_560, 3_840, 7_680], id: \.self) { pixels in
                            Text("\(pixels) px").tag(Optional(pixels))
                        }
                    }
                    .labelsHidden()
                }
                SettingRow("Audio bitrate") {
                    Picker("Audio bitrate per track", selection: $options.videoCompression.audioKbps) {
                        Text("Automatic").tag(Int?.none)
                        ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { kbps in
                            Text("\(kbps) kb/s per track").tag(Optional(kbps))
                        }
                    }
                    .labelsHidden()
                }
                Toggle("Keep exports that are not smaller", isOn: $options.keepLargerVideos)
            }
            .padding(.top, 9)
        }
        if let engineIssue {
            Text(engineIssue).font(.caption).foregroundStyle(.secondary)
        } else if selectedCapabilities == nil {
            ProgressView("Checking FFmpeg formats…").controlSize(.small)
        } else if review?.request != request, !inputs.isEmpty {
            ProgressView("Checking source compatibility…").controlSize(.small)
        } else {
            ForEach(Array(inputNotes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("Create 5-second sample", systemImage: "play.rectangle") {
                sampleRequest = request
                onSample()
            }
            .disabled(running || review?.request != request || review?.supportsFirstInput != true)
            if let sample, sampleRequest == request {
                Button("Open sample") { NSWorkspace.shared.open(sample.url) }
                if let bytes = sample.estimatedBytes {
                    Text("Estimated size: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: options.ffmpegExecutable) { await inspectEngine(options.ffmpegExecutable) }
        .task(id: CheckKey(request: request, hasCapabilities: selectedCapabilities != nil)) {
            await inspectInputs()
        }
        .onChange(of: options.videoFormat) { correctCodec() }
    }

    private struct CheckKey: Equatable {
        let request: CompressionReview.Request
        let hasCapabilities: Bool
    }

    private var installedFFmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private func chooseFFmpeg() {
        if let url = DeveloperToolFiles.choose() { selectEngine(url) }
    }

    private func selectEngine(_ executable: URL?) {
        guard options.ffmpegExecutable != executable else { return }
        review = nil
        options.ffmpegExecutable = executable
        if executable == nil {
            if options.videoCompression.rateControl == .constantQuality { options.videoCompression.rateControl = .preset }
            if options.videoFormat == .webm { options.videoFormat = .mp4 }
            correctCodec()
        }
    }

    private func correctCodec() {
        if !availableCodecs.isEmpty && !availableCodecs.contains(options.videoCodec) {
            options.videoCodec = availableCodecs.first ?? .automatic
        }
    }

    private func inspectEngine(_ executable: URL?) async {
        engineIssue = nil
        guard let executable else { return }
        do {
            let detected = try await VideoCompressionCapabilities.ffmpeg(executable)
            try Task.checkCancellation()
            guard options.ffmpegExecutable == executable else { return }
            capabilities = (executable, detected)
            if !availableFormats.contains(options.videoFormat), let format = availableFormats.first {
                options.videoFormat = format
            }
            correctCodec()
            if availableFormats.isEmpty {
                engineIssue = "This FFmpeg build lacks the encoders or muxers needed for the supported formats."
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, options.ffmpegExecutable == executable { engineIssue = error.localizedDescription }
        }
    }

    private func inspectInputs() async {
        guard let selectedCapabilities else { return }
        let key = request
        let snapshot = options
        var notes: [String] = []
        var availability: [Bool] = []
        for input in key.inputs {
            guard !Task.isCancelled, request == key else { return }
            do {
                let info = try await VideoCompression.preview(input, options: snapshot, capabilities: selectedCapabilities)
                availability.append(true)
                notes.append("\(input.lastPathComponent) · \(info.width) × \(info.height) · \(info.codec.rawValue)")
            } catch {
                availability.append(false)
                notes.append("\(input.lastPathComponent) · \(error.localizedDescription)")
            }
        }
        guard !Task.isCancelled, request == key else { return }
        inputNotes = notes
        review = CompressionReview(request: key, supportsFirstInput: availability.first == true,
                                   supportsAnyInput: availability.contains(true))
    }
}

private struct VideoBitrateField: View {
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        TextField("Video bitrate in kb/s", text: Binding(get: { text }, set: {
            text = $0
            value = Int($0) ?? -1
        }))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 105)
        .onAppear { text = value > 0 ? String(value) : "" }
        Text("kb/s · 64–100,000").font(.caption).foregroundStyle(.secondary)
    }
}
