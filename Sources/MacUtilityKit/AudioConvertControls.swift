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
                })) {
                    ForEach(AudioOutputFormat.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            SettingRow("Sample rate") {
                Picker("Sample rate", selection: $options.sampleRate) {
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
                        ForEach(AudioConvertOptions.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                    .labelsHidden()
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
}
