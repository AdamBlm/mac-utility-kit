import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct TranscribeDraft {
    var input: URL?
    var options = TranscriptionOptions()
    var cues: [SubtitleCue] = []
    var resultInput: URL?
    var resultSourceStamp: PDFSourceStamp?
    var resultLanguage: String?
    var forcedEnglish = false
    var format = TranscriptFormat.txt
    var task: Task<Void, Never>?
    var progress = 0.0
    var error: String?
}

struct TranscribeView: View {
    @Binding var draft: TranscribeDraft
    let onCaptionHandoff: (URL, String) -> Void

    @State private var inputSummary: InputSummary?
    @State private var inspectedModel: URL?
    @State private var modelCapability: Transcription.ModelCapability?
    @State private var modelRevision = 0
    @State private var startText: String?
    @State private var endText: String?
    @State private var listening: ListenRequest?
    @State private var player: AVAudioPlayer?
    @State private var playbackIssue: String?

    private struct InputSummary {
        let url: URL
        let duration: Double
        let hasVideo: Bool
    }

    private struct ModelRequest: Equatable {
        let url: URL?
        let revision: Int
    }

    private struct ListenRequest: Equatable {
        let id = UUID()
        let source: URL
        let cueIndex: Int
    }

    private var timeFormat: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(0...3))
    }

    private var activeSource: InputSummary? { inputSummary?.url == draft.input ? inputSummary : nil }

    private var invalidTimecode: Bool { draft.options.start < 0 || (draft.options.end ?? 0) < 0 }

    private var englishOnly: Bool {
        inspectedModel == draft.options.model && modelCapability == .englishOnly
    }

    private var unsupportedLanguage: Bool {
        englishOnly && draft.options.language != "auto" && draft.options.language != "en"
    }

    var body: some View {
        InteractiveToolLayout(tool: .transcribe) { palette in
            WorkspaceSection("Source", palette: palette) {
                HStack {
                    Button("Choose Audio or Video…", systemImage: "folder") {
                        if let url = DeveloperToolFiles.choose(allowedTypes: [.audio, .movie]) { replaceInput(url) }
                    }
                    if let input = draft.input {
                        Text(input.lastPathComponent).lineLimit(1).truncationMode(.middle).help(input.path)
                        if let duration = activeSource?.duration {
                            Text("\(duration.formatted(timeFormat)) s").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                timecodeControls
                if invalidTimecode {
                    Text("Enter seconds, MM:SS, or HH:MM:SS.").foregroundStyle(.red).font(.callout)
                }
            }
            .disabled(draft.task != nil)
            WorkspaceSection("Local transcription", palette: palette) {
                executablePicker("whisper-cli", selection: $draft.options.executable)
                SettingRow("Model") {
                    if let model = draft.options.model { Text(model.lastPathComponent).help(model.path) }
                    Button("Choose Model…") {
                        if let url = DeveloperToolFiles.choose() {
                            modelCapability = nil
                            draft.options.model = url
                            modelRevision += 1
                        }
                    }
                }
                SettingRow("Language") {
                    Picker("Language", selection: $draft.options.language) {
                        ForEach(Self.languages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .labelsHidden()
                }
                if unsupportedLanguage {
                    Text("This model supports only English. Choose English or a multilingual model.")
                        .font(.callout).foregroundStyle(.red)
                } else if englishOnly && draft.options.language == "auto" {
                    Text("This model supports only English. Auto-detect will use English.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(draft.task != nil)
            HStack {
                Button("Transcribe", systemImage: "waveform", action: run)
                    .disabled(draft.task != nil || draft.input == nil || draft.options.executable == nil ||
                              draft.options.model == nil || invalidTimecode || unsupportedLanguage)
                    .buttonStyle(.borderedProminent)
                if draft.task != nil {
                    ProgressView(value: draft.progress).controlSize(.small)
                    Button("Cancel") { draft.task?.cancel() }
                }
            }
            if let error = draft.error { Text(error).font(.callout).foregroundStyle(.red) }
            if let source = draft.resultInput, source == draft.input {
                WorkspaceSection("Transcript", palette: palette) {
                    if draft.forcedEnglish {
                        LabeledContent("Transcript language", value: "English · required by the model used")
                    } else if let language = draft.resultLanguage {
                        let name = Locale.current.localizedString(forLanguageCode: language) ?? language
                        LabeledContent("Transcript language", value: name)
                    }
                    if draft.cues.isEmpty {
                        Text("No speech was detected in the selection.").foregroundStyle(.secondary)
                    } else {
                        transcriptControls(source: source)
                    }
                }
                .disabled(draft.task != nil)
            }
        }
        .task(id: draft.input) { await inspect(draft.input) }
        .task(id: listening) {
            if let listening { await play(listening) }
        }
        .onChange(of: draft.input) { stopPlayback() }
        .onDisappear { stopPlayback() }
        .task(id: ModelRequest(url: draft.options.model, revision: modelRevision)) {
            guard !Task.isCancelled else { return }
            let model = draft.options.model
            modelCapability = model.flatMap { try? Transcription.modelCapability(at: $0) }
            inspectedModel = model
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard draft.task == nil, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            replaceInput(url)
            return true
        }
    }

    private static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"), ("ar", "Arabic"), ("zh", "Chinese"), ("en", "English"),
        ("fr", "French"), ("de", "German"), ("hi", "Hindi"), ("it", "Italian"), ("ja", "Japanese"),
        ("ko", "Korean"), ("nl", "Dutch"), ("pl", "Polish"), ("pt", "Portuguese"), ("ru", "Russian"),
        ("es", "Spanish"), ("sv", "Swedish"), ("tr", "Turkish"), ("uk", "Ukrainian")
    ]

    @ViewBuilder
    private var timecodeControls: some View {
        SettingRow("In point") {
            TextField("In point timecode", text: Binding(
                get: { startText ?? fieldTime(draft.options.start) },
                set: {
                    startText = $0
                    draft.options.start = VideoTimecode.seconds(from: $0) ?? -1
                }
            ))
            .frame(width: 100)
            .help("Seconds, MM:SS, or HH:MM:SS")
        }
        SettingRow("Out point") {
            if let end = draft.options.end {
                TextField("Out point timecode", text: Binding(
                    get: { endText ?? fieldTime(end) },
                    set: {
                        endText = $0
                        draft.options.end = VideoTimecode.seconds(from: $0) ?? -1
                    }
                ))
                .frame(width: 100)
                .help("Seconds, MM:SS, or HH:MM:SS")
                Button("Use End") {
                    endText = nil
                    draft.options.end = nil
                }
            } else {
                Text("End of source").foregroundStyle(.secondary)
                Button("Set Time") { draft.options.end = activeSource?.duration ?? draft.options.start + 1 }
            }
        }
    }

    @ViewBuilder
    private func transcriptControls(source: URL) -> some View {
        if let playbackIssue {
            Label(playbackIssue, systemImage: "exclamationmark.circle").font(.callout)
        }
        ForEach(draft.cues.indices, id: \.self) { index in
            let cue = draft.cues[index]
            HStack(spacing: 6) {
                let isListening = listening?.cueIndex == index
                Button(isListening ? "Stop Segment \(index + 1)" : "Play Segment \(index + 1)",
                       systemImage: isListening ? "stop.circle" : "play.circle") {
                    stopPlayback()
                    if !isListening { listening = ListenRequest(source: source, cueIndex: index) }
                }
                .labelStyle(.iconOnly)
                .disabled(draft.resultSourceStamp == nil)
                if isListening && player == nil { ProgressView().controlSize(.small) }
                Text("\(SubRip.timestamp(cue.startMilliseconds))–\(SubRip.timestamp(cue.endMilliseconds))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            TextField("Segment \(index + 1)", text: Binding(get: {
                draft.cues[index].text
            }, set: {
                guard draft.cues.indices.contains(index) else { return }
                draft.cues[index] = SubtitleCue(startMilliseconds: cue.startMilliseconds,
                                                endMilliseconds: cue.endMilliseconds, text: $0)
            }), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
        }
        SettingRow("Export format") {
            Picker("Export format", selection: $draft.format) {
                ForEach(TranscriptFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        HStack {
            Button("Copy", systemImage: "doc.on.doc") {
                DeveloperToolFiles.copy(Transcription.render(draft.cues, format: draft.format))
            }
            Button("Export…", systemImage: "square.and.arrow.up") {
                do {
                    let text = Transcription.render(draft.cues, format: draft.format)
                    try DeveloperToolFiles.save(Data(text.utf8), as: "transcript.\(draft.format.fileExtension)")
                    draft.error = nil
                } catch {
                    draft.error = error.localizedDescription
                }
            }
            if activeSource?.hasVideo == true {
                Button("Use as Burn-In Captions", systemImage: "captions.bubble") {
                    onCaptionHandoff(source, Transcription.render(draft.cues, format: .srt))
                }
            }
        }
    }

    private func play(_ request: ListenRequest) async {
        guard listening == request else { return }
        guard draft.resultInput == request.source, let sourceStamp = draft.resultSourceStamp,
              draft.cues.indices.contains(request.cueIndex) else {
            stopPlayback()
            return
        }
        let cue = draft.cues[request.cueIndex]
        do {
            let audio = try await Transcription.previewAudio(request.source, cue: cue, sourceStamp: sourceStamp)
            try Task.checkCancellation()
            guard listening == request else { return }
            let playback = try AVAudioPlayer(data: audio)
            guard playback.play() else { throw ToolError.invalid("Could not play this transcript segment.") }
            player = playback
            while playback.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
            if listening == request { stopPlayback() }
        } catch {
            guard !Task.isCancelled, listening == request else { return }
            stopPlayback()
            playbackIssue = error.localizedDescription
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        listening = nil
        playbackIssue = nil
    }

    private func fieldTime(_ value: Double) -> String { value < 0 ? "" : value.formatted(timeFormat) }

    private func replaceInput(_ input: URL) {
        stopPlayback()
        draft.input = input
        draft.resultInput = nil
        draft.resultSourceStamp = nil
        draft.resultLanguage = nil
        draft.forcedEnglish = false
        draft.cues = []
        draft.options.start = 0
        draft.options.end = nil
        startText = nil
        endText = nil
        draft.error = nil
    }

    private func inspect(_ input: URL?) async {
        inputSummary = nil
        guard let input, input.isFileURL else { return }
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0, !Task.isCancelled else { return }
        let hasVideo = (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false
        if !Task.isCancelled { inputSummary = InputSummary(url: input, duration: duration, hasVideo: hasVideo) }
    }

    private func run() {
        guard draft.task == nil, let input = draft.input else { return }
        stopPlayback()
        let options = draft.options
        draft.progress = 0.02
        draft.error = nil
        let center = ExportActivityCenter.shared
        let job = center.start(.transcribe) { draft.task?.cancel() }
        draft.task = Task {
            defer {
                center.finish(job)
                draft.task = nil
            }
            do {
                let result = try await Transcription.runWithLanguage(input, options: options) { fraction in
                    await MainActor.run {
                        guard draft.input == input else { return }
                        draft.progress = fraction
                        center.update(job, fraction: fraction)
                    }
                }
                guard !Task.isCancelled, draft.input == input else { return }
                draft.cues = result.cues
                draft.resultLanguage = result.language
                draft.forcedEnglish = result.forcedEnglish
                draft.resultInput = input
                draft.resultSourceStamp = result.sourceStamp
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled, draft.input == input { draft.error = error.localizedDescription }
            }
        }
    }
}
