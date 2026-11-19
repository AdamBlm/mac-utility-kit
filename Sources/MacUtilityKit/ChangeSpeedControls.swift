import AVKit
import SwiftUI
import UtilityCore

struct ChangeSpeedReview {
    let inputs: [URL]
    var sources: [URL: Result<ChangeSpeed.SourceInfo, Error>] = [:]

    func permitsExport(options: ChangeSpeedOptions) -> Bool {
        inputs.allSatisfy { sources[$0] != nil } && sources.values.contains {
            guard let info = try? $0.get() else { return false }
            return info.exportIssue(options: options) == nil
        }
    }

    func issue(for file: URL, options: ChangeSpeedOptions) -> String? {
        switch sources[file] {
        case .success(let info): info.exportIssue(options: options)
        case .failure(let error): error.localizedDescription
        case nil: nil
        }
    }
}

struct ChangeSpeedControls: View {
    let inputs: [URL]
    @Binding var options: ChangeSpeedOptions
    @Binding var review: ChangeSpeedReview?
    @State private var custom = false
    @State private var customInput: String?
    @State private var showsPlayback = false
    @State private var previewInput: URL?
    @State private var revision = 0

    private struct Inspection: Equatable {
        let inputs: [URL]
        let priority: URL?
        let revision: Int
    }

    private static let presets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]

    private var activeInput: URL? {
        if let previewInput, inputs.contains(previewInput) { return previewInput }
        return inputs.first
    }

    private var previewSources: [URL] {
        var seen = Set<URL>()
        return inputs.filter { seen.insert($0).inserted }
    }

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
        let inspection = Inspection(inputs: inputs, priority: activeInput, revision: revision)
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
            if previewSources.count > 1 {
                SettingRow("Preview file") {
                    Picker("Preview file", selection: Binding(get: { activeInput }, set: { previewInput = $0 })) {
                        ForEach(Array(previewSources.enumerated()), id: \.element) { index, input in
                            Text("\(index + 1). \(input.lastPathComponent)").tag(Optional(input))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let source = activeInput, review?.inputs == inputs, let result = review?.sources[source] {
                if let sourceInfo = try? result.get(), options.isValid {
                    let issue = sourceInfo.exportIssue(options: options)
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("Original duration", value: durationLabel(sourceInfo.duration))
                        LabeledContent("Adjusted duration", value: durationLabel(sourceInfo.duration / options.multiplier))
                    }
                    .font(.callout.monospacedDigit())
                    .frame(maxWidth: 310)
                    if showsPlayback {
                        Button("Close Preview") { showsPlayback = false }
                        ChangeSpeedPreview(input: source, options: options)
                    } else {
                        Button("Preview Adjusted Speed", systemImage: "play.rectangle") { showsPlayback = true }
                            .disabled(issue != nil)
                        if let issue, inputs.count == 1 {
                            Text(issue)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } else if inputs.count == 1, case .failure(let error) = result {
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !inputs.isEmpty {
                Button("Recheck Clips", systemImage: "arrow.clockwise") {
                    showsPlayback = false
                    review = nil
                    revision += 1
                }
                if review?.inputs != inputs || !inputs.allSatisfy({ review?.sources[$0] != nil }) {
                    ProgressView("Checking clips…").controlSize(.small)
                }
                if options.isValid, let review, review.inputs == inputs, inputs.count > 1 {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { index, file in
                        if let issue = review.issue(for: file, options: options) {
                            Text("\(index + 1). \(file.lastPathComponent) · \(issue)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Exports the primary video and audio tracks as MP4.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .task(id: inspection) { await loadSourceInfo(inspection) }
        .onDisappear { review = nil }
        .onChange(of: activeInput) { showsPlayback = false }
        .onChange(of: options) { showsPlayback = false }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let rounded = (seconds * 100).rounded() / 100
        return Duration.seconds(rounded).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 2)))
    }

    private func loadSourceInfo(_ request: Inspection) async {
        guard !Task.isCancelled, revision == request.revision else { return }
        if review?.inputs != request.inputs { review = ChangeSpeedReview(inputs: request.inputs) }
        let ordered = (request.priority.map { [$0] } ?? []) + request.inputs.filter { $0 != request.priority }
        for source in ordered where review?.sources[source] == nil {
            let result: Result<ChangeSpeed.SourceInfo, Error>
            do { result = .success(try await ChangeSpeed.sourceInfo(source)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, revision == request.revision, review?.inputs == request.inputs else { return }
            review?.sources[source] = result
        }
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
            } else if let player, let item = player.currentItem {
                VStack(alignment: .leading, spacing: 6) {
                    VideoPlayer(player: player)
                        .frame(height: 210)
                        .accessibilityLabel("Adjusted speed preview")
                    Text("Short sample from the first visible frame.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .onReceive(item.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
                    guard status == .failed else { return }
                    playbackFailed(item.error, item: item)
                }
                .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                                 object: item).receive(on: DispatchQueue.main)) { note in
                    playbackFailed(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error, item: item)
                }
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

    private func playbackFailed(_ error: (any Error)?, item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        player?.pause()
        issue = error?.localizedDescription ?? "Could not play the adjusted speed sample."
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
