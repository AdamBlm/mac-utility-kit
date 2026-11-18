import SwiftUI
import UtilityCore

struct RegexTesterDraft: Equatable {
    var pattern = ""
    var sample = ""
    var replacement = ""
    var previewsReplacement = false
    var options = RegexTesterOptions()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.previewsReplacement == rhs.previewsReplacement && lhs.options == rhs.options
            && lhs.pattern.utf8.elementsEqual(rhs.pattern.utf8)
            && lhs.sample.utf8.elementsEqual(rhs.sample.utf8)
            && lhs.replacement.utf8.elementsEqual(rhs.replacement.utf8)
    }
}

struct RegexTesterView: View {
    @Binding var draft: RegexTesterDraft
    @State private var result: Result<RegexTester.Evaluation, Error>?
    @State private var request: Request?

    private struct Request: Equatable {
        let id = UUID()
        let pattern: String
        let sample: String
        let replacement: String?
        let options: RegexTesterOptions
    }

    var body: some View {
        InteractiveToolLayout(tool: .regexTester) { palette in
            WorkspaceSection("Pattern and Sample", palette: palette) {
                TextField("Regular expression", text: $draft.pattern)
                    .font(.body.monospaced())
                TextEditor(text: $draft.sample)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Sample text")
                Toggle("Ignore case", isOn: $draft.options.ignoresCase)
                Toggle("Match ^ and $ on each line", isOn: $draft.options.multiline)
                Toggle("Allow . to match a newline", isOn: $draft.options.dotMatchesNewlines)
                Toggle("Preview replacement", isOn: $draft.previewsReplacement)
                if draft.previewsReplacement {
                    TextField("Replacement", text: $draft.replacement)
                        .font(.body.monospaced())
                    Text("Use $1 for a numbered capture, ${name} for a named capture, and \\$ for a literal dollar sign.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Run Test", systemImage: "play.fill") {
                        result = nil
                        request = Request(pattern: draft.pattern, sample: draft.sample,
                                          replacement: draft.previewsReplacement ? draft.replacement : nil,
                                          options: draft.options)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(request != nil)
                    Text("ICU regular expressions · UTF-16 offsets").font(.callout).foregroundStyle(.secondary)
                    if request != nil { ProgressView().controlSize(.small) }
                }
            }
            if let result {
                WorkspaceSection("Results", palette: palette) {
                    switch result {
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(.secondary)
                    case .success(let output):
                        Text("Matches: \(output.matches.count)")
                        if !output.matches.isEmpty {
                            Button("Copy match previews", systemImage: "doc.on.doc") {
                                DeveloperToolFiles.copy(output.matches.compactMap { $0.captures.first?.text }.joined(separator: "\n"))
                            }
                            ScrollView {
                                LazyVStack(alignment: .leading) {
                                    ForEach(output.matches) { match in
                                        DisclosureGroup(matchLabel(match)) {
                                            ForEach(match.captures) { capture in
                                                Text("\(capture.name ?? String(capture.id)): \(capture.text ?? "Unmatched")")
                                                    .font(.body.monospaced())
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 240)
                        }
                        if let replacement = output.replacement {
                            Button("Copy replacement", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(replacement) }
                            ScrollView { Text(replacement).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 180)
                        }
                    }
                }
            }
        }
        .task(id: request) {
            guard let request else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try RegexTester.evaluate(pattern: request.pattern, sample: request.sample,
                                         replacement: request.replacement, options: request.options)
            }
            let completed = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, self.request == request else { return }
            result = completed
            self.request = nil
        }
        .onChange(of: draft) {
            request = nil
            result = nil
        }
        .onDisappear { request = nil }
    }

    private func matchLabel(_ match: RegexTester.Match) -> String {
        guard let capture = match.captures.first, let range = capture.range else { return "Match \(match.id + 1)" }
        if range.isEmpty { return "Empty match at \(range.lowerBound)" }
        return "[\(range.lowerBound)–\(range.upperBound)] \(capture.text ?? "")"
    }
}
