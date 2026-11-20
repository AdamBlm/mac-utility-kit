import SwiftUI
import UtilityCore

struct AudioConvertControls: View {
    let inputs: [URL]
    @Binding var options: AudioConvertOptions

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
            if options.supportsMetadata {
                Toggle("Preserve compatible metadata", isOn: $options.preservesMetadata)
            } else {
                Text("This encoder does not transfer metadata to \(options.format.title).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if options.format.requiresFFmpeg {
                executablePicker("FFmpeg", selection: $options.ffmpegExecutable)
            }
            if let issue = options.validationIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func adjustBitrate() {
        guard options.isLossy, !options.supportedBitrates.contains(options.bitrate),
              let nearest = options.supportedBitrates.min(by: {
                  abs($0 - options.bitrate) < abs($1 - options.bitrate)
              }) else { return }
        options.bitrate = nearest
    }
}
