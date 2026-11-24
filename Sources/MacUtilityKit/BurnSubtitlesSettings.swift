import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct BurnSubtitlesSettings: View {
    let inputs: [URL]
    @Binding var options: BurnSubtitlesOptions
    var onTranscribe: ((URL) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSource: URL?
    @State private var duration: Double?
    @State private var loadedInput: URL?
    @State private var playhead = 0.0
    @State private var preview: CGImage?
    @State private var completedPreview: Request?
    @State private var previewError: String?
    @State private var inputError: String?
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?
    private var importing: Bool { importTask != nil }
    private var subtitleType: UTType { UTType(filenameExtension: "srt") ?? .plainText }
    @State private var batchReview: BatchReview?

    private struct BatchRequest: Equatable, Sendable {
        let inputs: [URL]
        let srt: String
        let offset: Double
    }

    private struct BatchReview: Sendable {
        struct Row: Sendable {
            let url: URL
            let description: String
            let isIssue: Bool
        }

        let request: BatchRequest
        let rows: [Row]
    }

    private struct Request: Equatable {
        let input: URL
        let playhead: Double
        let options: BurnSubtitlesOptions
    }

    private var timeFormat: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(0...3))
    }

    private var previewInputs: [URL] {
        var seen = Set<URL>()
        return inputs.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let previews = previewInputs
        let input = selectedSource.flatMap { previews.contains($0) ? $0 : nil } ?? previews.first
        let palette = WorkspacePalette(dark: colorScheme == .dark, category: .video)
        let batch = BatchRequest(inputs: inputs, srt: options.srt, offset: options.offset)
        if previews.count > 1 {
            SettingRow("Preview video") {
                Picker("Preview video", selection: Binding(get: { input }, set: { selectedSource = $0 })) {
                    ForEach(previews, id: \.self) { url in
                        let name = url.lastPathComponent
                        let duplicateName = previews.contains { $0 != url && $0.lastPathComponent == name }
                        Text(duplicateName ? url.path : name).tag(Optional(url))
                    }
                }
                .labelsHidden()
                .help(input?.path ?? "")
            }
            Text("Subtitle text, timing, and style apply to every queued video.")
                .font(.callout).foregroundStyle(.secondary)
        }
        HStack {
            Button("Import SRT…", systemImage: "folder", action: importSRT)
                .disabled(importing)
            ClipboardFileButton(allowedTypes: [subtitleType], buttonOnlyTitle: "Paste SRT File", onPasteFile: loadSRT)
                .disabled(importing)
            if let input, let onTranscribe {
                Button("Generate Captions…", systemImage: "waveform") { onTranscribe(input) }
                    .disabled(importing)
            }
        }
        .task(id: input) { await load(input) }
        if inputs.count > 1, onTranscribe != nil {
            Text("Sending captions back from Transcribe replaces this batch with the captioned video.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if importing {
            HStack {
                ProgressView("Reading subtitles…").controlSize(.small)
                Button("Cancel Import", action: cancelImport)
            }
        }
        TextEditor(text: $options.srt)
            .font(.body.monospaced())
            .frame(minHeight: 150)
            .scrollContentBackground(.hidden)
            .padding(6)
            .workspaceInset(palette)
            .accessibilityLabel("SRT subtitle text and timing")
            .disabled(importing)
        if let importError { Text(importError).font(.callout).foregroundStyle(.red) }
        SettingRow("Timing offset") {
            TextField("Offset in seconds", value: $options.offset, format: timeFormat)
                .frame(width: 95)
            Text("seconds").foregroundStyle(.secondary)
        }
        SettingRow("Font size") {
            Slider(value: Binding(get: { Double(options.fontSize) }, set: { options.fontSize = Int($0) }),
                   in: 8...80, step: 1)
                .accessibilityLabel("Subtitle font size")
            Text(options.fontSize.formatted()).monospacedDigit()
        }
        SettingRow("Colors") {
            ColorPicker("Text", selection: colorBinding($options.textRGB), supportsOpacity: false)
            ColorPicker("Background", selection: colorBinding($options.backgroundRGB), supportsOpacity: false)
        }
        SettingRow("Background") {
            Picker("Background", selection: $options.background) {
                ForEach(SubtitleBackground.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }
        SettingRow("Position") {
            Picker("Position", selection: $options.position) {
                ForEach(SubtitlePosition.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        executablePicker("FFmpeg with libass", selection: $options.ffmpegExecutable)
            .onDisappear(perform: cancelImport)
        if let issue = options.engineIssue {
            Text(issue).font(.callout).foregroundStyle(.secondary)
        }
        if inputs.count > 1, options.hasSubtitles {
            batchPlan(batch)
        }
        if let input, loadedInput == input, let duration {
            if options.hasSubtitles {
                switch Result(catching: { try BurnSubtitles.plan(duration: duration, options: options) }) {
                case .success(let plan):
                    Text("\(plan.cues.count) cues · \(plan.clipped) clipped · \(plan.removed) outside video")
                        .foregroundStyle(.secondary).font(.callout)
                    if options.engineIssue == nil {
                        previewControls(input: input, duration: duration, palette: palette)
                    }
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(.red).font(.callout)
                }
            }
        } else {
            if loadedInput == input, let inputError {
                Text(inputError).foregroundStyle(.red).font(.callout)
            }
            if options.hasSubtitles, let issue = options.subtitleIssue {
                Text(issue).foregroundStyle(.red).font(.callout)
            }
        }
    }

    @ViewBuilder
    private func batchPlan(_ request: BatchRequest) -> some View {
        Group {
            if let batchReview, batchReview.request == request {
                let rows = batchReview.rows
                if !rows.isEmpty {
                    DisclosureGroup("Per-file subtitle timing") {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(index + 1). \(row.url.lastPathComponent)").lineLimit(1).help(row.url.path)
                                Text(row.description).foregroundStyle(row.isIssue ? Color.red : Color.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    let unready = rows.count { $0.isIssue }
                    if unready > 0 {
                        Text(unready == 1 ? "1 video cannot use these subtitles." : "\(unready) videos cannot use these subtitles.")
                            .font(.callout).foregroundStyle(.red)
                    }
                }
            } else {
                ProgressView("Checking subtitle timing…").controlSize(.small)
            }
        }
        .task(id: request) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                let rows = await Self.reviewBatch(request)
                try Task.checkCancellation()
                batchReview = BatchReview(request: request, rows: rows)
            } catch {}
        }
    }

    @concurrent
    private static func reviewBatch(_ request: BatchRequest) async -> [BatchReview.Row] {
        guard !Task.isCancelled, let cues = try? SubRip.parse(request.srt) else { return [] }
        var timing = BurnSubtitlesOptions()
        timing.offset = request.offset
        var rows: [BatchReview.Row] = []
        for url in request.inputs {
            guard !Task.isCancelled else { return [] }
            do {
                let duration = try await TrimVideo.duration(of: url)
                let plan = try BurnSubtitles.plan(duration: duration, options: timing, parsedCues: cues)
                let description = "\(plan.cues.count) cues · \(plan.clipped) clipped · \(plan.removed) outside video"
                rows.append(.init(url: url, description: description, isIssue: false))
            } catch is CancellationError {
                return []
            } catch {
                rows.append(.init(url: url, description: error.localizedDescription, isIssue: true))
            }
        }
        return rows
    }

    @ViewBuilder
    private func previewControls(input: URL, duration: Double, palette: WorkspacePalette) -> some View {
        let maximum = max(duration - 0.001, duration * 0.999)
        let request = Request(input: input, playhead: min(playhead, maximum), options: options)
        VStack(alignment: .leading, spacing: 8) {
            if completedPreview == request, let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: 250)
                    .accessibilityLabel("Rendered subtitle preview")
            } else if completedPreview == request, let previewError {
                Text(previewError).foregroundStyle(.red).font(.callout)
            } else {
                ProgressView("Rendering subtitle preview…").controlSize(.small)
            }
            Slider(value: $playhead, in: 0...maximum).accessibilityLabel("Subtitle preview playhead")
            Text("\(playhead.formatted(timeFormat)) seconds")
                .monospacedDigit().font(.callout).foregroundStyle(.secondary)
        }
        .task(id: request) { await renderPreview(request) }
    }

    private func load(_ source: URL?) async {
        guard !Task.isCancelled else { return }
        duration = nil
        playhead = 0
        loadedInput = nil
        inputError = nil
        guard let source else { return }
        do {
            let result = try await TrimVideo.duration(of: source)
            guard !Task.isCancelled else { return }
            duration = result
            loadedInput = source
        } catch {
            guard !Task.isCancelled else { return }
            inputError = error.localizedDescription
            loadedInput = source
        }
    }

    private func renderPreview(_ request: Request) async {
        do {
            try await Task.sleep(for: .milliseconds(250))
            let rendered = try await BurnSubtitles.preview(request.input, at: request.playhead, options: request.options)
            guard !Task.isCancelled else { return }
            preview = rendered
            previewError = nil
            completedPreview = request
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            previewError = error.localizedDescription
            completedPreview = request
        }
    }

    private func importSRT() {
        guard let url = DeveloperToolFiles.choose(allowedTypes: [subtitleType]) else { return }
        loadSRT(url)
    }

    private func loadSRT(_ url: URL) {
        guard importTask == nil else { return }
        importError = nil
        importTask = Task {
            do {
                let subtitles = try await SubRip.load(url)
                try Task.checkCancellation()
                options.srt = subtitles
            } catch {
                guard !Task.isCancelled else { return }
                importError = error.localizedDescription
            }
            importTask = nil
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
    }

    private func colorBinding(_ value: Binding<UInt32>) -> Binding<Color> {
        Binding {
            let rgb = value.wrappedValue
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        } set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let red = UInt32((max(0, min(1, rgb.redComponent)) * 255).rounded())
            let green = UInt32((max(0, min(1, rgb.greenComponent)) * 255).rounded())
            let blue = UInt32((max(0, min(1, rgb.blueComponent)) * 255).rounded())
            value.wrappedValue = (red << 16) | (green << 8) | blue
        }
    }
}
