import SwiftUI
import UtilityCore

struct AudioConvertControls: View {
    let inputs: [URL]
    @Binding var options: AudioConvertOptions
    @State private var reviewRevision = 0
    @State private var reviewed: ReviewRequest?
    @State private var formats: [URL: AudioConvert.SourceFormat] = [:]

    private struct ReviewRequest: Equatable {
        let inputs: [URL]
        let revision: Int
    }

    private var request: ReviewRequest { ReviewRequest(inputs: inputs, revision: reviewRevision) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Format") {
                Picker("Audio format", selection: Binding(get: { options.format }, set: { format in
                    options.format = format
                    if let rate = options.sampleRate, !options.supportedRates.contains(rate) {
                        options.sampleRate = nil
                    }
                    adjustBitrate()
                })) {
                    ForEach(AudioOutputFormat.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            if options.automaticallyAdjustsSettings {
                Text("Automatic keeps the source settings when the output format supports them.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if options.sampleRate == nil && options.channels == .source {
                Text("Defaults to the source sample rate and channels.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Automatic audio settings", isOn: $options.automaticallyAdjustsSettings)
                    if !options.automaticallyAdjustsSettings {
                        SettingRow("Sample rate") {
                            Picker("Sample rate", selection: Binding(get: { options.sampleRate }, set: { rate in
                                options.sampleRate = rate
                                adjustBitrate()
                            })) {
                                Text("Same as input").tag(Int?.none)
                                ForEach(options.supportedRates, id: \.self) { rate in
                                    Text("\((Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...3)))) kHz")
                                        .tag(Optional(rate))
                                }
                            }
                            .labelsHidden()
                        }
                        SettingRow("Channels") {
                            Picker("Channels", selection: $options.channels) {
                                ForEach(AudioConvertOptions.Channels.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                        }
                        if options.isLossy {
                            SettingRow("Bitrate") {
                                Picker("Audio bitrate", selection: $options.bitrate) {
                                    ForEach(options.supportedBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                                }
                                .labelsHidden()
                            }
                            if options.format == .mp3 && options.sampleRate == nil {
                                Text("Available bitrates depend on each input’s sample rate.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        } else if options.format == .flac {
                            SettingRow("Compression") {
                                Stepper("Level \(options.losslessCompression)", value: $options.losslessCompression, in: 0...8)
                            }
                        } else {
                            Text("24-bit PCM").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if options.supportsMetadata {
                        Toggle("Preserve compatible metadata", isOn: $options.preservesMetadata)
                    } else {
                        Text("This encoder does not transfer metadata to \(options.format.title).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
            if options.format.requiresFFmpeg {
                executablePicker("FFmpeg", selection: $options.ffmpegExecutable)
            }
            if let issue = options.validationIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            } else {
                sourceReview
            }
        }
        .task(id: options.format) {
            if options.format.requiresFFmpeg && options.ffmpegExecutable == nil {
                options.ffmpegExecutable = HomebrewEngine.ffmpeg.installed
            }
        }
        .task(id: request) { [request] in await inspect(request) }
    }

    @ViewBuilder
    private var sourceReview: some View {
        if !inputs.isEmpty {
            if reviewed != request {
                ProgressView("Reading audio formats…").controlSize(.small)
            } else {
                let issues = inputs.compactMap { input -> (file: URL, issue: String)? in
                    guard let format = formats[input] else {
                        return (input, "Source format unavailable. The encoder will check this file.")
                    }
                    if let issue = options.sourceIssue(format) { return (input, issue) }
                    return options.automaticAdjustment(for: format).map { (input, "Automatic · " + $0) }
                }
                ForEach(Array(issues.enumerated()), id: \.offset) { _, row in
                    Text("\(row.file.lastPathComponent) · \(row.issue)")
                        .font(.callout).foregroundStyle(.secondary).help(row.file.path)
                }
                Button("Recheck Audio Formats", systemImage: "arrow.clockwise") { reviewRevision += 1 }
            }
        }
    }

    private func inspect(_ request: ReviewRequest) async {
        let inputs = request.inputs
        let worker = Task.detached(priority: .userInitiated) {
            var result: [URL: AudioConvert.SourceFormat] = [:]
            for input in Set(inputs) {
                guard !Task.isCancelled else { break }
                result[input] = AudioConvert.sourceFormat(input)
            }
            return result
        }
        let inspected = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        formats = inspected
        reviewed = request
    }

    private func adjustBitrate() {
        guard options.isLossy, !options.supportedBitrates.contains(options.bitrate),
              let nearest = options.supportedBitrates.min(by: {
                  abs($0 - options.bitrate) < abs($1 - options.bitrate)
              }) else { return }
        options.bitrate = nearest
    }
}
