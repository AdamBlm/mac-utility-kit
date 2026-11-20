import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct TextToSpeechDraft {
    enum Section: String, CaseIterable, Identifiable {
        case all = "All text", selected = "Selected text"
        var id: Self { self }
    }

    var text = ""
    var sourceName: String?
    var pdfSource: URL?
    var pdfPages = ""
    var voiceID: String?
    var rate: Float = 1
    var section = Section.all
    var exportFormat = SpeechAudioFormat.wav
}

struct TextToSpeechView: View {
    @Binding var draft: TextToSpeechDraft
    @State private var selection: TextSelection?
    @State private var voices: [TextToSpeechVoice] = []
    @State private var artifact: Artifact?
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position = 0.0
    @State private var renderTask: Task<Void, Never>?
    @State private var exportTask: Task<Void, Never>?
    @State private var importTask: Task<Void, Never>?
    @State private var pdfPassword = ""
    @State private var recognizesScans = false
    @State private var issue: String?

    private struct Artifact {
        let request: TextToSpeechRequest
        let audio: TextToSpeechAudio
    }

    private var text: Binding<String> {
        Binding(get: { draft.text }, set: { edited in
            importTask?.cancel()
            importTask = nil
            selection = nil
            draft.text = edited
        })
    }

    private var selectedText: String {
        guard let selection else { return "" }
        switch selection.indices {
        case .selection(let range): return excerpt(range)
        case .multiSelection(let ranges): return ranges.ranges.map(excerpt).joined(separator: "\n\n")
        @unknown default: return ""
        }
    }

    private func excerpt(_ range: Range<String.Index>) -> String {
        let string = draft.text
        guard range.lowerBound >= string.startIndex, range.upperBound <= string.endIndex else { return "" }
        return String(string[range])
    }

    var body: some View {
        let content = draft.section == .all ? draft.text : selectedText
        let request = TextToSpeechRequest(text: content, voiceID: draft.voiceID, rate: draft.rate)
        let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let exceedsLimit = content.count > TextToSpeechRequest.maximumCharacters
        InteractiveToolLayout(tool: .textToSpeech) { palette in
            WorkspaceSection("Text", palette: palette) {
                TextEditor(text: text, selection: $selection)
                    .frame(minHeight: 145, idealHeight: 185)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Text to speak")
                HStack {
                    Button("Open Document…", systemImage: "folder") { openDocument() }
                    ClipboardFileButton(allowedTypes: documentTypes, onPasteFile: importDocument)
                    Button("Paste Text", systemImage: "doc.on.clipboard") {
                        if let pasted = NSPasteboard.general.string(forType: .string) {
                            text.wrappedValue = pasted
                            draft.sourceName = nil
                            draft.pdfSource = nil
                            draft.pdfPages = ""
                            pdfPassword = ""
                            recognizesScans = false
                            issue = nil
                        }
                    }
                    Spacer()
                    if importTask != nil {
                        ProgressView().controlSize(.small)
                        Button("Cancel Import") {
                            importTask?.cancel()
                            importTask = nil
                        }
                    }
                    else if let name = draft.sourceName { Text(name).lineLimit(1).foregroundStyle(.secondary) }
                }
                if let pdf = draft.pdfSource {
                    Toggle("Recognize Text in Scans", isOn: $recognizesScans)
                        .disabled(importTask != nil)
                    SettingRow("PDF password") {
                        SecureField("If required", text: $pdfPassword)
                            .onSubmit {
                                loadDocument(pdf, pages: draft.pdfPages, password: pdfPassword, recognizesScans: recognizesScans)
                            }
                    }
                    .disabled(importTask != nil)
                    SettingRow("PDF pages") {
                        if draft.sourceName != pdf.lastPathComponent {
                            Text(pdf.lastPathComponent).lineLimit(1)
                                .foregroundStyle(.secondary)
                                .help(pdf.path)
                        }
                        TextField("All or e.g. 1, 3–5", text: $draft.pdfPages)
                            .accessibilityLabel("PDF pages from \(pdf.lastPathComponent)")
                            .help(pdf.path)
                        Button("Load Pages") {
                            loadDocument(pdf, pages: draft.pdfPages, password: pdfPassword, recognizesScans: recognizesScans)
                        }
                            .help("Load text from \(pdf.lastPathComponent)")
                    }
                    .disabled(importTask != nil)
                }
                SettingRow("Section") {
                    Picker("Section", selection: $draft.section) {
                        ForEach(TextToSpeechDraft.Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                if draft.section == .selected, !hasText {
                    Text("Highlight a section of text to speak it.").font(.callout).foregroundStyle(.secondary)
                }
            }
            WorkspaceSection("Speech", palette: palette) {
                SettingRow("Voice") {
                    Picker("Voice", selection: $draft.voiceID) {
                        Text("System default").tag(String?.none)
                        if let id = draft.voiceID, !voices.contains(where: { $0.id == id }) {
                            Text("Unavailable voice").tag(Optional(id))
                        }
                        ForEach(voices) { voice in
                            let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
                            Text(([voice.name, language] + [voice.quality].compactMap { $0 }).joined(separator: " · "))
                                .tag(Optional(voice.id))
                        }
                    }
                    .labelsHidden()
                    Button("Refresh voices", systemImage: "arrow.clockwise") { voices = TextToSpeech.voices() }
                        .labelStyle(.iconOnly)
                }
                SettingRow("Speech rate") {
                    Slider(value: $draft.rate, in: 0.5...1.5, step: 0.05)
                        .accessibilityLabel("Speech rate")
                    Text(Double(draft.rate).formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                if exceedsLimit {
                    Text("Select up to 20,000 characters at a time.").font(.callout).foregroundStyle(.secondary)
                }
                if renderTask != nil {
                    HStack {
                        ProgressView("Generating audio…").controlSize(.small)
                        Button("Cancel") { cancelRender() }
                    }
                } else if let artifact, artifact.request == request {
                    playback(artifact.audio)
                } else {
                    Button("Generate Audio", systemImage: "waveform") { render(request) }
                        .disabled(!hasText || exceedsLimit)
                }
                if exportTask != nil {
                    HStack {
                        ProgressView("Exporting audio…").controlSize(.small)
                        Button("Cancel Export") { exportTask?.cancel() }
                    }
                }
                if let issue { Text(issue).font(.callout).foregroundStyle(.red) }
            }
        }
        .task { voices = TextToSpeech.voices() }
        .task(id: playing) { await followPlayback() }
        .onChange(of: request) { cancelRender() }
        .onDisappear {
            cancelRender()
            importTask?.cancel()
            importTask = nil
            pdfPassword = ""
            exportTask?.cancel()
        }
    }

    private func playback(_ audio: TextToSpeechAudio) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Slider(value: Binding(get: { position }, set: { time in
                player?.currentTime = time
                position = time
            }), in: 0...audio.duration)
            .accessibilityLabel("Seek through generated speech")
            HStack {
                Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                    toggle(audio)
                }
                Text("\(time(position)) / \(time(audio.duration))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Picker("Export format", selection: $draft.exportFormat) {
                    ForEach(SpeechAudioFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .labelsHidden()
                .disabled(exportTask != nil)
                Button("Export…", systemImage: "square.and.arrow.up") { save(audio) }
                    .disabled(exportTask != nil)
            }
        }
    }

    private var documentTypes: [UTType] {
        [.plainText, .rtf, .pdf] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }

    private func openDocument() {
        guard let url = DeveloperToolFiles.choose(allowedTypes: documentTypes) else { return }
        importDocument(url)
    }

    private func importDocument(_ url: URL) {
        draft.pdfSource = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true ? url : nil
        draft.pdfPages = ""
        pdfPassword = ""
        recognizesScans = false
        loadDocument(url, pages: "", password: "")
    }

    private func loadDocument(_ url: URL, pages: String, password: String, recognizesScans: Bool = false) {
        importTask?.cancel()
        issue = nil
        importTask = Task {
            do {
                let loaded = try await SpeechDocument.loadForSpeech(
                    url, pages: pages, password: password, recognizesScans: recognizesScans
                )
                guard !Task.isCancelled else { return }
                selection = nil
                draft.text = loaded
                draft.section = .all
                draft.sourceName = url.lastPathComponent
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription
            }
            importTask = nil
        }
    }

    private func render(_ request: TextToSpeechRequest) {
        cancelRender()
        renderTask = Task {
            do {
                let audio = try await TextToSpeech.render(request)
                guard !Task.isCancelled else { return }
                player = try AVAudioPlayer(data: audio.wave)
                artifact = Artifact(request: request, audio: audio)
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription
            }
            renderTask = nil
        }
    }

    private func cancelRender() {
        renderTask?.cancel()
        renderTask = nil
        artifact = nil
        player?.stop()
        player = nil
        playing = false
        position = 0
        issue = nil
    }

    private func toggle(_ audio: TextToSpeechAudio) {
        guard let player else { return }
        issue = nil
        if playing {
            player.pause()
            position = player.currentTime
            playing = false
            return
        }
        if position >= audio.duration || position >= player.duration { position = 0 }
        player.currentTime = position
        playing = player.play()
        if !playing { issue = "Could not play the generated audio." }
    }

    private func followPlayback() async {
        guard playing, let player else { return }
        while playing, !Task.isCancelled {
            if !player.isPlaying {
                position = artifact?.audio.duration ?? player.duration
                playing = false
                break
            }
            position = player.currentTime
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(seconds)
            .formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 1)))
    }

    private func save(_ audio: TextToSpeechAudio) {
        guard exportTask == nil else { return }
        let format = draft.exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
        panel.nameFieldStringValue = "Speech." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        issue = nil
        let center = ExportActivityCenter.shared
        let job = center.start(.textToSpeech) { exportTask?.cancel() }
        exportTask = Task {
            defer {
                center.finish(job)
                exportTask = nil
            }
            do {
                let data = try await audio.encoded(as: format)
                try Task.checkCancellation()
                try data.write(to: url, options: .atomic)
                center.postCompletion(.textToSpeech, outputs: 1)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}
