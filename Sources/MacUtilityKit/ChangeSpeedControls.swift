import AVKit
import SwiftUI
import UtilityCore

struct ChangeSpeedControls: View {
    let inputs: [URL]
    @Binding var options: ChangeSpeedOptions
    @State private var custom = false
    @State private var customInput: String?
    @State private var loadedSource: URL?
    @State private var originalDuration: Double?
    @State private var previewError: String?
    @State private var showsPlayback = false

    private static let presets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]

    private var selectedPreset: Binding<Double?> {
        Binding {
            if custom || !Self.presets.contains(options.multiplier) { return nil }
            return options.multiplier
        } set: { preset in
            custom = preset == nil
            if let preset {
                options.multiplier = preset
                customInput = nil
            }
        }
    }

    private var multiplierText: Binding<String> {
        Binding {
            customInput ?? (options.multiplier.isFinite ? options.multiplier.formatted() : "")
        } set: { value in
            customInput = value
            let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = Locale.current.decimalSeparator ?? "."
            options.multiplier = Double(input.replacingOccurrences(of: separator, with: ".")) ?? 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Speed") {
                Picker("Speed", selection: selectedPreset) {
                    ForEach(Self.presets, id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(Optional(speed))
                    }
                    Text("Custom").tag(Double?.none)
                }
                .labelsHidden()
                if selectedPreset.wrappedValue == nil {
                    TextField("Speed multiplier", text: multiplierText)
                        .frame(width: 76)
                    Text("×").foregroundStyle(.secondary)
                }
            }
            if !options.isValid {
                Text("Enter a speed between 0.25× and 4×.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Preserve audio pitch", isOn: $options.preservesPitch)
            if !options.preservesPitch, options.isValid, options.multiplier != 1 {
                Text("Videos with audio require FFmpeg when pitch preservation is off.")
                    .font(.callout).foregroundStyle(.secondary)
                executablePicker("FFmpeg", selection: $options.ffmpegExecutable)
            }
            if let source = inputs.first, source == loadedSource {
                if let originalDuration, options.isValid {
                    VStack(alignment: .leading, spacing: 5) {
                        if inputs.count > 1 {
                            Text(source.lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        LabeledContent("Original duration", value: durationLabel(originalDuration))
                        LabeledContent("Adjusted duration", value: durationLabel(originalDuration / options.multiplier))
                    }
                    .font(.callout.monospacedDigit())
                    .frame(maxWidth: 310)
                    if showsPlayback {
                        Button("Close Preview") { showsPlayback = false }
                        ChangeSpeedPreview(input: source, options: options)
                    } else {
                        Button("Preview Adjusted Speed", systemImage: "play.rectangle") { showsPlayback = true }
                    }
                } else if let previewError {
                    Text(previewError).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Exports the primary video and audio tracks as MP4.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .task(id: inputs.first) { await loadDuration(inputs.first) }
        .onChange(of: inputs.first) { showsPlayback = false }
        .onChange(of: options) { showsPlayback = false }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let rounded = (seconds * 100).rounded() / 100
        return Duration.seconds(rounded).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 2)))
    }

    private func loadDuration(_ source: URL?) async {
        loadedSource = nil
        originalDuration = nil
        previewError = nil
        guard let source else { return }
        do {
            let duration = try await ChangeSpeed.sourceDuration(source)
            guard !Task.isCancelled else { return }
            originalDuration = duration
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
        loadedSource = source
    }
}

private struct ChangeSpeedPreview: View {
    let input: URL
    let options: ChangeSpeedOptions
    @State private var player: AVPlayer?
    @State private var directory: URL?
    @State private var issue: String?

    var body: some View {
        Group {
            if let issue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            } else if let player {
                VideoPlayer(player: player)
                    .frame(height: 210)
                    .accessibilityLabel("Adjusted speed preview")
            } else {
                ProgressView("Preparing preview…").controlSize(.small)
            }
        }
        .task { await prepare() }
        .onDisappear {
            player?.pause()
            player = nil
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = nil
        }
    }

    private func prepare() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacUtilityKit-Speed-\(UUID())")
        let output = folder.appending(path: "Preview.mp4")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try await ChangeSpeed.preview(input, to: output, options: options)
            try Task.checkCancellation()
            directory = folder
            player = AVPlayer(url: output)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }
}
