import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ExtractSubtitlesView: View {
    @Binding var inputs: [URL]
    @State private var chosenInput: URL?
    @State private var probeOverride: URL?
    @State private var encoderOverride: URL?
    @State private var inventory: SubtitleInventory?
    @State private var selectedTrack: Int?
    @State private var format = ExtractedSubtitleFormat.srt
    @State private var task: Task<Void, Never>?
    @State private var phase = ""
    @State private var error: String?
    @State private var output: URL?
    private let engines = VideoEngineSettings.shared

    private var source: URL? {
        if let chosenInput, inputs.contains(chosenInput) { return chosenInput }
        return inputs.first
    }

    private var encoder: URL? {
        encoderOverride ?? engines.installed?.ffmpeg ?? HomebrewVideoTools.ffmpegPair()?.ffmpeg
    }

    private var probe: URL? {
        probeOverride ?? encoder?.deletingLastPathComponent().appendingPathComponent("ffprobe")
            .flatMapExecutable() ?? HomebrewVideoTools.ffmpegPair()?.ffprobe
    }

    private var track: EmbeddedSubtitleTrack? {
        inventory?.tracks.first { $0.id == selectedTrack && $0.supportsTextExport }
    }

    var body: some View {
        InteractiveToolLayout(tool: .extractSubtitles) { palette in
            WorkspaceSection("Source", palette: palette) {
                if inputs.count > 1 {
                    Picker("Video", selection: Binding(get: { source }, set: { chosenInput = $0 })) {
                        ForEach(inputs, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                    }
                } else if let source {
                    Text(source.lastPathComponent).textSelection(.enabled)
                }
                Button(source == nil ? "Choose Video" : "Choose Another Video", systemImage: "film") {
                    if let file = DeveloperToolFiles.choose(allowedTypes: Self.videoTypes) { inputs = [file] }
                }
                if encoder == nil || probe == nil {
                    executablePicker("FFmpeg", selection: $encoderOverride)
                    executablePicker("ffprobe", selection: $probeOverride)
                } else {
                    DisclosureGroup("Advanced") {
                        executablePicker("FFmpeg", selection: $encoderOverride)
                        executablePicker("ffprobe", selection: $probeOverride)
                    }
                }
                Button("Inspect Tracks", systemImage: "list.bullet", action: inspect)
                    .disabled(source == nil || probe == nil)
            }
            .disabled(task != nil)

            if let inventory {
                WorkspaceSection("Subtitles", palette: palette) {
                    if inventory.tracks.isEmpty {
                        Text("This video has no embedded subtitle tracks.").foregroundStyle(.secondary)
                    } else {
                        Picker("Track", selection: $selectedTrack) {
                            Text("Choose a track").tag(nil as Int?)
                            ForEach(inventory.tracks) { Text($0.label).tag(Optional($0.id)) }
                        }
                        if selectedTrack != nil && track == nil {
                            Text("This track cannot be converted to text subtitles.").foregroundStyle(.secondary)
                        }
                        Picker("Format", selection: $format) {
                            ForEach(ExtractedSubtitleFormat.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button("Export Subtitles…", systemImage: "square.and.arrow.up", action: export)
                            .buttonStyle(.borderedProminent).disabled(track == nil || encoder == nil)
                    }
                }
                .disabled(task != nil)
            }
            if let task {
                HStack {
                    ProgressView(phase).controlSize(.small)
                    Spacer()
                    Button("Cancel") { task.cancel() }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let output {
                WorkspaceSection("Saved File", palette: palette) {
                    Text(output.lastPathComponent).textSelection(.enabled)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                }
            }
        }
        .task { await engines.refresh() }
        .onChange(of: source) { reset() }
        .onChange(of: probeOverride) { reset() }
        .onChange(of: encoderOverride) { reset() }
    }

    private static var videoTypes: [UTType] {
        [.movie, .mpeg4Movie, .quickTimeMovie] + ["mkv", "webm"].compactMap { UTType(filenameExtension: $0) }
    }

    private func reset() {
        task?.cancel()
        inventory = nil
        selectedTrack = nil
        output = nil
        error = nil
    }

    private func inspect() {
        guard let source, let probe else { return }
        reset()
        let managed = engines.installed
        run("Inspecting subtitle tracks…") {
            defer { withExtendedLifetime(managed) {} }
            let result = try await SubtitleExtraction.inspect(source, executable: probe)
            try Task.checkCancellation()
            inventory = result
            selectedTrack = result.tracks.first(where: \.supportsTextExport)?.id
        }
    }

    private func export() {
        guard let source, let inventory, let track, let encoder else { return }
        let format = format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.resolvingSymlinksInPath().standardizedFileURL != source.resolvingSymlinksInPath().standardizedFileURL else {
            error = "Choose a different filename from the source video."
            return
        }
        let managed = engines.installed
        run("Extracting subtitles…", isExport: true) {
            defer { withExtendedLifetime(managed) {} }
            let data = try await SubtitleExtraction.extract(track, from: inventory, as: format, executable: encoder)
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
            output = destination
        }
    }

    private func run(
        _ title: String, isExport: Bool = false, operation: @escaping @MainActor () async throws -> Void
    ) {
        guard task == nil else { return }
        error = nil
        output = nil
        phase = title
        let activity = ExportActivityCenter.shared
        let job = isExport ? activity.start(.extractSubtitles) { task?.cancel() } : nil
        if let job { activity.update(job, fraction: nil, phase: title) }
        task = Task {
            defer {
                if let job { activity.finish(job) }
                task = nil
            }
            do {
                try await operation()
                if isExport { activity.postCompletion(.extractSubtitles, outputs: 1) }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

private extension URL {
    func flatMapExecutable() -> URL? {
        guard FileManager.default.isExecutableFile(atPath: path),
              (try? resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return nil }
        return self
    }
}
