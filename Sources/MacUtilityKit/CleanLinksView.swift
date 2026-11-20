import SwiftUI
import UtilityCore

struct CleanLinksDraft {
    var input = ""
    var output: [CleanLinkRow] = []
    var unwrapRedirects = true
}

struct CleanLinkRow: Identifiable {
    let id: Int
    let input: String
    let result: Result<CleanLinks.Result, Error>
}

struct CleanLinksView: View {
    @Binding var draft: CleanLinksDraft
    @State private var issue: String?

    var body: some View {
        InteractiveToolLayout(tool: .cleanLinks) { palette in
            WorkspaceSection("Links", palette: palette) {
                TextEditor(text: $draft.input)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Links, one per line")
                Toggle("Replace recognized redirects with their destination", isOn: $draft.unwrapRedirects)
                Button("Clean Links", systemImage: "link", action: clean)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let issue {
                    Text(issue).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !draft.output.isEmpty {
                WorkspaceSection("Results", palette: palette) {
                    let links = draft.output.compactMap { try? $0.result.get().cleaned }
                    Button("Copy cleaned links", systemImage: "doc.on.doc") {
                        DeveloperToolFiles.copy(links.joined(separator: "\n"))
                    }
                    .disabled(links.isEmpty)
                    ForEach(draft.output) { row in
                        switch row.result {
                        case .success(let result):
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.cleaned).textSelection(.enabled)
                                    if let destination = result.redirectDestination {
                                        Text(result.cleaned == result.original ? "Kept redirect to \(destination)"
                                                                             : "Redirect destination: \(destination)")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    if result.keptSignedQuery {
                                        Text("Kept the query because the link appears to be signed.")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    if !result.removedParameters.isEmpty {
                                        Text("Removed: \(result.removedParameters.joined(separator: ", "))")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Copy link", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(result.cleaned) }
                                    .labelStyle(.iconOnly)
                            }
                        case .failure(let error):
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.input).textSelection(.enabled)
                                Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: draft.input) {
            draft.output.removeAll()
            issue = nil
        }
        .onChange(of: draft.unwrapRedirects) {
            if !draft.output.isEmpty { clean() }
        }
    }

    private func clean() {
        guard draft.input.utf8.count <= 1_048_576 else {
            issue = "Enter up to 1 MB of links at a time."
            return
        }
        let lines = draft.input.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count <= 500 else {
            issue = "Enter up to 500 links at a time."
            return
        }
        draft.output = lines.enumerated().map { index, line in
            CleanLinkRow(id: index, input: line, result: Result {
                try CleanLinks.clean(line, unwrapRedirects: draft.unwrapRedirects)
            })
        }
        issue = nil
    }
}
