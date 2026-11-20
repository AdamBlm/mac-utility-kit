import AppKit
import SwiftUI
import UtilityCore

struct VideoDownloadDraft {
    var address = ""
    var executable: URL?
    var selection = VideoDownloadSelection()
    var destination = URL.downloadsDirectory
    var inspected: InspectedVideo?
    var result: URL?
    var task: Task<Void, Never>?
    var downloading = false
    var activeDownload: UUID?
    var progress: VideoDownloadProgress?
    var error: String?
}

struct InspectedVideo {
    let source: URL
    let executable: URL
    let engines: ManagedVideoEngines?
    let deno: URL?
    let fallbackFFmpeg: URL?
    let info: VideoDownloadInfo
}

struct VideoDownloadView: View {
    @Binding var draft: VideoDownloadDraft
    private let engineSettings = VideoEngineSettings.shared
    @State private var homebrew = HomebrewVideoTools()
    @State private var checkedHomebrew = false
    private var downloader: URL? {
        draft.executable ?? engineSettings.installed?.downloader ?? homebrew.downloader
    }
    private var needsSetup: Bool {
        downloader == nil && engineSettings.available
    }
    private var inspected: InspectedVideo? {
        guard let value = draft.inspected, value.source == (try? VideoDownload.sourceURL(draft.address)),
              value.executable == downloader else { return nil }
        return value
    }

    var body: some View {
        InteractiveToolLayout(tool: .downloadVideo) { palette in
            WorkspaceSection("Source", palette: palette) {
                TextField("Video URL", text: $draft.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(inspect)
                if engineSettings.available {
                    DisclosureGroup("Advanced") {
                        executablePicker("yt-dlp", selection: $draft.executable)
                    }
                } else {
                    executablePicker("yt-dlp", selection: $draft.executable)
                }
                if !engineSettings.available, homebrew.downloader == nil || homebrew.ffmpeg == nil {
                    DisclosureGroup("Set Up with Homebrew") {
                        HomebrewVideoSetup {
                            homebrew = .discover()
                            checkedHomebrew = true
                        }
                        if checkedHomebrew {
                            Text(homebrew.downloader == nil ? "Homebrew yt-dlp was not found." : "Homebrew FFmpeg and FFprobe were not found.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if draft.executable == nil, engineSettings.installed == nil, homebrew.downloader != nil {
                    Text("Using Homebrew yt-dlp").font(.callout).foregroundStyle(.secondary)
                }
                Button(needsSetup ? "Install Video Tools" : "Inspect Link",
                       systemImage: needsSetup ? "arrow.down.circle" : "list.bullet", action: inspect)
                    .disabled((downloader == nil && !engineSettings.available)
                              || (try? VideoDownload.sourceURL(draft.address)) == nil)
            }
            .disabled(draft.task != nil)
            if let inspected {
                WorkspaceSection("Download", palette: palette) {
                    options(inspected)
                }
                .disabled(draft.task != nil)
            }
            if draft.task != nil {
                HStack {
                    if draft.downloading {
                        downloadProgress
                    } else {
                        ProgressView(engineSettings.progress ?? "Inspecting link…").controlSize(.small)
                    }
                    Spacer()
                    Button("Cancel") { draft.task?.cancel() }
                }
            }
            if let error = draft.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let result = draft.result {
                WorkspaceSection("Saved File", palette: palette) {
                    Text(result.lastPathComponent).textSelection(.enabled)
                    HStack {
                        Button("Open") { NSWorkspace.shared.open(result) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    }
                }
            }
        }
        .task {
            homebrew = .discover()
            await engineSettings.refresh()
        }
        .onDisappear { if !draft.downloading { draft.task?.cancel() } }
        .onChange(of: draft.address) { draft.error = nil }
    }

    private func options(_ inspected: InspectedVideo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(inspected.info.title).font(.headline)
            if let duration = inspected.info.duration, (0...3_153_600_000).contains(duration) {
                Text(Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingRow("Output") {
                Picker("Output", selection: $draft.selection.output) {
                    ForEach(VideoDownloadOutput.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            if !draft.selection.output.audioOnly {
                streamPicker("Video", items: inspected.info.formats.filter(\.hasVideo), selection: $draft.selection.videoID)
            }
            let includesAudio = !draft.selection.output.audioOnly
                && inspected.info.formats.contains { $0.id == draft.selection.videoID && $0.hasAudio }
            if includesAudio {
                Text("The selected stream includes audio.").font(.callout).foregroundStyle(.secondary)
            } else {
                streamPicker("Audio", items: inspected.info.formats.filter { $0.hasAudio && !$0.hasVideo },
                             selection: $draft.selection.audioID)
            }
            if inspected.fallbackFFmpeg != nil {
                DisclosureGroup("Advanced") {
                    executablePicker("FFmpeg", selection: $draft.selection.ffmpeg)
                }
            } else {
                executablePicker("FFmpeg", selection: $draft.selection.ffmpeg)
            }
            HStack {
                Button(draft.destination.lastPathComponent, systemImage: "folder") { chooseDestination() }
                    .help("Choose an output folder")
                Spacer()
                Button("Download", systemImage: "arrow.down.circle") { download(inspected) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func streamPicker(_ label: String, items: [VideoDownloadFormat], selection: Binding<String?>) -> some View {
        SettingRow(label) {
            Picker(label, selection: selection) {
                Text("Automatic").tag(nil as String?)
                ForEach(items) { stream in
                    let detail = [stream.height.map { "\($0)p" }, stream.language, stream.ext,
                                  stream.note, Optional(stream.id)].compactMap { $0 }
                    Text(detail.joined(separator: " · ")).tag(Optional(stream.id))
                }
            }
            .labelsHidden()
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = draft.destination
        if panel.runModal() == .OK, let url = panel.url { draft.destination = url }
    }

    private func inspect() {
        guard draft.task == nil, let source = try? VideoDownload.sourceURL(draft.address) else { return }
        draft.error = nil
        draft.downloading = false
        draft.task = Task {
            defer { draft.task = nil }
            do {
                let custom = draft.executable
                var engines = custom == nil ? engineSettings.installed : nil
                if needsSetup { engines = try await engineSettings.install() }
                guard let executable = custom ?? engines?.downloader ?? homebrew.downloader else { return }
                let deno = engines?.deno ?? (custom == nil ? homebrew.deno : nil)
                let fallbackFFmpeg = engines?.ffmpeg ?? homebrew.ffmpeg
                let info = try await VideoDownload.inspect(
                    source, executable: executable, deno: deno,
                    ffmpeg: draft.selection.ffmpeg ?? fallbackFFmpeg
                )
                try Task.checkCancellation()
                draft.selection.videoID = nil
                draft.selection.audioID = nil
                draft.inspected = InspectedVideo(source: source, executable: executable, engines: engines,
                                                 deno: deno, fallbackFFmpeg: fallbackFFmpeg, info: info)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                draft.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var downloadProgress: some View {
        switch draft.progress {
        case let .transfer(kind, fraction):
            let title = transferTitle(kind)
            if let fraction {
                ProgressView(title, value: fraction)
            } else {
                ProgressView(title).controlSize(.small)
            }
        case .processing, .complete:
            ProgressView("Finishing download…").controlSize(.small)
        case nil:
            ProgressView("Starting download…").controlSize(.small)
        }
    }

    private func transferTitle(_ kind: VideoDownloadProgress.Kind) -> String {
        switch kind {
        case .video: "Downloading video…"
        case .audio: "Downloading audio…"
        case .combined: "Downloading media…"
        }
    }

    private func download(_ inspected: InspectedVideo) {
        guard draft.task == nil else { return }
        var selection = draft.selection
        selection.ffmpeg = selection.ffmpeg ?? inspected.fallbackFFmpeg
        if !selection.output.audioOnly,
           inspected.info.formats.contains(where: { $0.id == selection.videoID && $0.hasAudio }) {
            selection.audioID = nil
        }
        let destination = draft.destination
        draft.error = nil
        draft.downloading = true
        draft.progress = nil
        let center = ExportActivityCenter.shared
        let job = center.start(.downloadVideo) { draft.task?.cancel() }
        center.update(job, fraction: nil, phase: "Starting download…")
        draft.activeDownload = job
        draft.task = Task {
            defer {
                center.finish(job)
                draft.task = nil
                draft.downloading = false
                draft.activeDownload = nil
            }
            do {
                draft.result = try await VideoDownload.downloadWithProgress(
                    inspected.source, info: inspected.info, executable: inspected.executable,
                    selection: selection, destination: destination, deno: inspected.deno
                ) { value in
                    await MainActor.run {
                        guard draft.activeDownload == job else { return }
                        var update = value
                        if case let .transfer(kind, fraction?) = value,
                           case let .transfer(previousKind, previous?) = draft.progress, kind == previousKind {
                            update = .transfer(kind, max(previous, fraction))
                        }
                        guard draft.progress != update else { return }
                        draft.progress = update
                        switch update {
                        case let .transfer(kind, fraction): center.update(job, fraction: fraction, phase: transferTitle(kind))
                        case .processing: center.update(job, fraction: nil, phase: "Finishing download…")
                        case .complete: center.update(job, fraction: 1)
                        }
                    }
                }
                center.postCompletion(.downloadVideo, outputs: 1)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                draft.error = error.localizedDescription
            }
        }
    }
}
