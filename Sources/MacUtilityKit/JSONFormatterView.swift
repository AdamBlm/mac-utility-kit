import AppKit
import SwiftUI
import UtilityCore

struct JSONFormatterDraft {
    var text = ""
    var indentation = JSONIndentation.twoSpaces
    var sortKeys = false
}

struct JSONFormatterView: View {
    @Binding var draft: JSONFormatterDraft
    @State private var result: JSONFormatResult?
    @State private var error: String?
    @State private var outputInput: Input?
    @State private var fileError: String?
    @State private var exportError: String?
    @State private var isLoading = false

    private struct Input: Equatable, Sendable {
        let text: String
        let indentation: JSONIndentation
        let sortKeys: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.indentation == rhs.indentation && lhs.sortKeys == rhs.sortKeys &&
                lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
    }

    var body: some View {
        let input = Input(text: draft.text, indentation: draft.indentation, sortKeys: draft.sortKeys)
        InteractiveToolLayout(tool: .jsonFormatter) { palette in
            WorkspaceSection("JSON input", palette: palette) {
                TextEditor(text: $draft.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("JSON input")
                    .disabled(isLoading)
                HStack {
                    Button("Open file…", systemImage: "folder", action: openFile)
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        if let text = NSPasteboard.general.string(forType: .string) { draft.text = text }
                    }
                    Spacer()
                    Button("Clear") { draft.text = "" }
                        .disabled(draft.text.isEmpty)
                }
                .disabled(isLoading)
                if isLoading { ProgressView("Opening file…").controlSize(.small) }
                if let fileError { Text(fileError).foregroundStyle(.red).font(.callout) }
            }
            WorkspaceSection("Format", palette: palette) {
                SettingRow("Indentation") {
                    Picker("Indentation", selection: $draft.indentation) {
                        ForEach(JSONIndentation.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                Toggle("Sort object keys", isOn: $draft.sortKeys)
            }
            WorkspaceSection("Output", palette: palette) {
                if isLoading {
                    Text("Output will update when the file opens.").foregroundStyle(.secondary)
                } else if outputInput != input && !input.text.isEmpty {
                    ProgressView("Formatting…").controlSize(.small)
                } else if let error, outputInput == input {
                    Text(error).foregroundStyle(.red)
                } else if let result, outputInput == input {
                    if !result.duplicateOccurrences.isEmpty {
                        DisclosureGroup {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(result.duplicateOccurrences.indices, id: \.self) { index in
                                        let duplicate = result.duplicateOccurrences[index]
                                        Text("\(String(reflecting: duplicate.key)) · line \(duplicate.line), column \(duplicate.column)")
                                            .font(.callout.monospaced())
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: min(CGFloat(result.duplicateOccurrences.count) * 24, 144))
                        } label: {
                            Label("Duplicate keys preserved (\(result.duplicateOccurrences.count))",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    let preview = result.text.prefix(20_000)
                    ScrollView([.horizontal, .vertical]) {
                        Text(preview).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).padding(8)
                            .frame(minWidth: 30, alignment: .leading)
                    }
                    .frame(minHeight: 130, idealHeight: 200, maxHeight: 300)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    if preview.endIndex != result.text.endIndex {
                        Text("Preview limited to 20,000 characters. Copy and export include the full result.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(result.text) }
                        Button("Export…", systemImage: "square.and.arrow.up") {
                            do {
                                try DeveloperToolFiles.save(Data(result.text.utf8), as: "formatted.json")
                                exportError = nil
                            } catch {
                                exportError = error.localizedDescription
                            }
                        }
                    }
                    if let exportError { Text(exportError).foregroundStyle(.red).font(.callout) }
                } else {
                    Text("Enter JSON to see the formatted result.").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: input) {
            result = nil
            error = nil
            exportError = nil
            guard !input.text.isEmpty else {
                outputInput = input
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let work = Task.detached(priority: .userInitiated) {
                    try JSONFormatter.format(input.text, indentation: input.indentation, sortKeys: input.sortKeys)
                }
                let formatted = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                if !Task.isCancelled {
                    result = formatted
                    outputInput = input
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    outputInput = input
                }
            }
        }
    }

    private func openFile() {
        guard let url = DeveloperToolFiles.choose(allowedTypes: [.json, .plainText]) else { return }
        fileError = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do { draft.text = try DeveloperToolFiles.utf8(await DeveloperToolFiles.read(url)) }
            catch { fileError = error.localizedDescription }
        }
    }
}
