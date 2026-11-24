import SwiftUI
import UtilityCore

struct AudioMergeControls: View {
    @Binding var inputs: [URL]
    @Binding var options: AudioMergeOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Format") {
                Picker("Format", selection: $options.format) {
                    ForEach(AudioOutputFormat.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            SettingRow("Transition") {
                Picker("Transition", selection: $options.transition) {
                    ForEach(AudioMergeOptions.Transition.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            if options.transition != .cut {
                SettingRow("Duration (ms)") {
                    TextField("Duration in milliseconds", value: $options.transitionMilliseconds, format: .number)
                        .labelsHidden().frame(width: 85)
                }
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow("Sample Rate") {
                        Picker("Sample Rate", selection: $options.sampleRate) {
                            Text("44.1 kHz").tag(44_100)
                            Text("48 kHz").tag(48_000)
                        }
                        .labelsHidden()
                    }
                    SettingRow("Channels") {
                        Picker("Channels", selection: $options.stereo) {
                            Text("Stereo").tag(true)
                            Text("Mono").tag(false)
                        }
                        .labelsHidden()
                    }
                }
                .padding(.top, 6)
            }
            executablePicker("FFmpeg", selection: $options.ffmpegExecutable)
            if let issue = options.validationIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
            if !inputs.isEmpty {
                Divider()
                Text("Clip Order").font(.subheadline.weight(.semibold))
                ForEach(Array(inputs.enumerated()), id: \.offset) { index, input in
                    let name = input.lastPathComponent
                    HStack {
                        Text("\(index + 1). \(name)").lineLimit(1).truncationMode(.middle)
                            .help(input.path)
                        Spacer()
                        Button("Move \(name) up", systemImage: "chevron.up") {
                            move(input, at: index, by: -1)
                        }
                        .labelStyle(.iconOnly).disabled(index == 0)
                        Button("Move \(name) down", systemImage: "chevron.down") {
                            move(input, at: index, by: 1)
                        }
                        .labelStyle(.iconOnly).disabled(index == inputs.count - 1)
                    }
                }
                if inputs.count == 1 {
                    Text("Add a second clip to merge.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard options.ffmpegExecutable == nil else { return }
            options.ffmpegExecutable = HomebrewVideoTools.ffmpegPair()?.ffmpeg
        }
    }

    private func move(_ input: URL, at index: Int, by offset: Int) {
        guard inputs.indices.contains(index), inputs[index] == input,
              inputs.indices.contains(index + offset) else { return }
        inputs.swapAt(index, index + offset)
    }
}
