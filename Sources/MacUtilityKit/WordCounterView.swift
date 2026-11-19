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
    @State private var count = WordCount.empty
    @State private var isCounting = false
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?

    private struct AnalysisInput: Equatable {
        let text: String
        let options: WordCounterOptions
    }

    var body: some View {
        let input = AnalysisInput(text: draft.text, options: draft.options)
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
                    Button("Paste", systemImage: "doc.on.clipboard") {
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
                if isCounting {
                    ProgressView("Counting…").controlSize(.small)
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 16) {
                    GridRow {
                        statistic("Words", count.words.formatted())
                        statistic("Characters", count.characters.formatted())
                        statistic("Sentences", count.sentences.formatted())
                    }
                    GridRow {
                        statistic("Paragraphs", count.paragraphs.formatted())
                        statistic("Reading time", readingTime)
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
            if !count.frequentWords.isEmpty {
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
            guard !input.text.isEmpty else {
                isCounting = false
                count = .empty
                return
            }
            isCounting = true
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await WordCounter.analyze(input.text, options: input.options)
                guard !Task.isCancelled else { return }
                count = result
                isCounting = false
            } catch {
                if !Task.isCancelled { isCounting = false }
            }
        }
        .onDisappear { importTask?.cancel() }
    }

    private var readingTime: String {
        if count.readingSeconds < 60 { return "\(count.readingSeconds.formatted()) s" }
        let minutes = count.readingSeconds / 60
        let seconds = count.readingSeconds % 60
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
