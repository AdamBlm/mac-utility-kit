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

    private var reviewedInventory: SubtitleInventory? {
        guard let inventory, inventory.selection == source else { return nil }
        return inventory
    }

    private var track: EmbeddedSubtitleTrack? {
        reviewedInventory?.tracks.first { $0.id == selectedTrack && $0.supportsTextExport }
    }

    var body: some View {
        InteractiveToolLayout(tool: .extractSubtitles) { palette in
            WorkspaceSection("Source", palette: palette) {
                if inputs.count > 1 {
                    Picker("Video", selection: Binding(get: { source }, set: { chosenInput = $0 })) {
                        ForEach(Array(inputs.enumerated()), id: \.offset) { index, url in
                            Text("\(index + 1). \(url.lastPathComponent)").tag(Optional(url))
                        }
                    }
                } else if let source {
                    Text(source.lastPathComponent).textSelection(.enabled)
                }
                Button("Choose Videos…", systemImage: "film", action: chooseVideos)
                ClipboardFileButton(allowedTypes: Self.videoTypes, buttonOnlyTitle: "Paste Videos", onPaste: {
                    _ = setInputs($0)
                })
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

            if let inventory = reviewedInventory {
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
        .dropDestination(for: URL.self) { urls, _ in
            task == nil && setInputs(urls)
        }
        .task { await engines.refresh() }
        .onChange(of: source) { reset() }
        .onChange(of: probeOverride) { reset() }
        .onChange(of: encoderOverride) { reset() }
    }

    private static var videoTypes: [UTType] {
        [.movie, .mpeg4Movie, .quickTimeMovie] + ["mkv", "webm"].compactMap { UTType(filenameExtension: $0) }
    }

    private func chooseVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.videoTypes
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { _ = setInputs(panel.urls) }
    }

    private func setInputs(_ urls: [URL]) -> Bool {
        var seen = Set<URL>()
        let videos = urls.filter { LocalInputFile.matches($0, allowedTypes: Self.videoTypes) && seen.insert($0).inserted }
        guard !videos.isEmpty else { return false }
        reset()
        chosenInput = nil
        inputs = videos
        return true
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
        guard let source, let inventory = reviewedInventory, let track, let encoder else { return }
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
