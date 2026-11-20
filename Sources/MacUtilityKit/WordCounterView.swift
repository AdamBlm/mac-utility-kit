import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct WordCounterDraft {
    var text = ""
    var options = WordCounterOptions()
}

struct WordCounterView: View {
    @Binding var draft: WordCounterDraft
    @State private var analysis: (input: AnalysisInput, count: WordCount)?
    @State private var analysisError: (input: AnalysisInput, message: String)?
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?

    private struct AnalysisInput: Equatable {
        let text: String
        let options: WordCounterOptions
    }

    var body: some View {
        let input = AnalysisInput(text: draft.text, options: draft.options)
        let analyzedCount = analysis?.input == input ? analysis?.count : nil
        let count: WordCount? = input.text.isEmpty ? .empty : analyzedCount
        let error = analysisError?.input == input ? analysisError?.message : nil
        InteractiveToolLayout(tool: .wordCounter) { palette in
            WorkspaceSection("Text", palette: palette) {
                TextEditor(text: Binding(get: { draft.text }, set: { replaceText($0) }))
                    .font(.body)
                    .frame(minHeight: 150, idealHeight: 205)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Text to count")
                HStack {
                    Button("Open text file…", systemImage: "folder") { chooseFile() }
                    ClipboardFileButton(allowedTypes: [.plainText], buttonOnlyTitle: "Paste File", onPasteFile: loadFile)
                    Button("Paste Text", systemImage: "doc.on.clipboard") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            replaceText(text)
                        }
                    }
                    Spacer()
                    Button("Clear") {
                        replaceText("")
                    }
                    .disabled(draft.text.isEmpty)
                }
                if let importError {
                    Text(importError).font(.callout).foregroundStyle(.secondary)
                }
            }
            WorkspaceSection("Counts", palette: palette) {
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else if count == nil {
                    ProgressView("Counting…").controlSize(.small)
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 16) {
                    GridRow {
                        statistic("Words", count?.words.formatted() ?? "—")
                        statistic("Characters", count?.characters.formatted() ?? "—")
                        statistic("Sentences", count?.sentences.formatted() ?? "—")
                    }
                    GridRow {
                        statistic("Paragraphs", count?.paragraphs.formatted() ?? "—")
                        statistic("Reading time", count.map { readingTime($0.readingSeconds) } ?? "—")
                    }
                }
                Divider()
                Toggle("Exclude whitespace from character count", isOn: $draft.options.excludesWhitespace)
                SettingRow("Reading speed") {
                    HStack(spacing: 7) {
                        TextField("Words per minute", value: $draft.options.wordsPerMinute, format: .number.grouping(.never))
                            .frame(width: 64)
                            .onSubmit {
                                if draft.options.wordsPerMinute < 1 { draft.options.wordsPerMinute = 1 }
                            }
                        Text("words/min").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let count, !count.frequentWords.isEmpty {
                WorkspaceSection("Frequent words", palette: palette) {
                    ForEach(count.frequentWords) { item in
                        HStack {
                            Text(item.word).textSelection(.enabled)
                            Spacer()
                            Text(item.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { files, _ in
            guard files.count == 1, let file = files.first, file.isFileURL else { return false }
            loadFile(file)
            return true
        }
        .task(id: input) {
            guard !Task.isCancelled else { return }
            analysis = nil
            analysisError = nil
            guard !input.text.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await WordCounter.analyze(input.text, options: input.options)
                try Task.checkCancellation()
                analysis = (input, result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                analysisError = (input, error.localizedDescription)
            }
        }
        .onDisappear { importTask?.cancel() }
    }

    private func readingTime(_ readingSeconds: Int) -> String {
        if readingSeconds < 60 { return "\(readingSeconds.formatted()) s" }
        let minutes = readingSeconds / 60
        let seconds = readingSeconds % 60
        return seconds == 0 ? "\(minutes.formatted()) min" : "\(minutes.formatted()) min \(seconds.formatted()) s"
    }

    private func statistic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func replaceText(_ text: String) {
        importTask?.cancel()
        importError = nil
        draft.text = text
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let input = panel.url else { return }
        loadFile(input)
    }

    private func loadFile(_ input: URL) {
        importTask?.cancel()
        importError = nil
        importTask = Task { @MainActor in
            do {
                let text = try await WordCounter.loadText(input)
                guard !Task.isCancelled else { return }
                draft.text = text
            } catch {
                if !Task.isCancelled { importError = error.localizedDescription }
            }
        }
    }
}
