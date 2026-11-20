import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct Base64ToolDraft {
    var text = ""
    var decoding = false
    var format = ByteEncoding.base64
    var padded = true
    var lineWidth = 0
    var file: URL?
}

struct Base64ToolView: View {
    @Binding var draft: Base64ToolDraft
    @State private var result: Output?
    @State private var error: String?
    @State private var exportError: String?
    @State private var outputInput: Input?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedFile: URL?

    private struct Input: Equatable, Sendable {
        let text: String
        let decoding: Bool
        let format: ByteEncoding
        let padded: Bool
        let lineWidth: Int
        let file: URL?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.file == rhs.file && lhs.decoding == rhs.decoding && lhs.format == rhs.format &&
                lhs.padded == rhs.padded && lhs.lineWidth == rhs.lineWidth &&
                lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }

        var usesFileExport: Bool {
            guard let file else { return false }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { return true }
            return size > 1_048_576
        }

        func convert() async throws -> Output {
            let source: Data
            if let file {
                source = try await DeveloperToolFiles.read(file)
            } else {
                source = Data(text.utf8)
            }
            let work = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                if decoding {
                    let decoded = try format.decode(bytes: source)
                    let text = String(data: decoded, encoding: .utf8)
                    let printable = text?.unicodeScalars.allSatisfy {
                        $0.properties.generalCategory != .control || [9, 10, 13].contains($0.value)
                    } ?? false
                    return Output(data: decoded, text: printable ? text : nil, filename: printable ? "decoded.txt" : "decoded.bin")
                }
                let encoded = format.encode(source, padded: padded, wrapAt: lineWidth)
                return Output(data: Data(encoded.utf8), text: encoded, filename: "encoded.txt")
            }
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        }
    }

    private struct Output: Sendable {
        let data: Data
        let text: String?
        let filename: String
    }

    var body: some View {
        let input = Input(text: draft.text, decoding: draft.decoding, format: draft.format, padded: draft.padded,
                          lineWidth: draft.lineWidth, file: draft.file)
        InteractiveToolLayout(tool: .base64) { palette in
            WorkspaceSection("Conversion", palette: palette) {
                Picker("Operation", selection: $draft.decoding) {
                    Text("Encode").tag(false)
                    Text("Decode").tag(true)
                }
                .pickerStyle(.segmented)
                SettingRow("Encoding") {
                    Picker("Encoding", selection: $draft.format) {
                        ForEach(ByteEncoding.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                if !draft.decoding {
                    if draft.format.supportsPadding {
                        Toggle("Include padding", isOn: $draft.padded)
                    }
                    SettingRow("Line wrapping") {
                        Picker("Line wrapping", selection: $draft.lineWidth) {
                            Text("Off").tag(0)
                            Text("64 characters").tag(64)
                            Text("76 characters").tag(76)
                            Text("128 characters").tag(128)
                        }
                        .labelsHidden()
                    }
                }
            }
            WorkspaceSection("Input", palette: palette) {
                if let file = draft.file {
                    Label(file.lastPathComponent, systemImage: "doc")
                } else {
                    TextEditor(text: $draft.text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Text input")
                }
                HStack {
                    Button("Open file…", systemImage: "folder") {
                        if let url = DeveloperToolFiles.choose() { draft.file = url }
                    }
                    ClipboardFileButton(allowedTypes: [.data], buttonOnlyTitle: "Paste File",
                                        onPasteFile: { draft.file = $0 })
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            draft.file = nil
                            draft.text = text
                        }
                    }
                    Spacer()
                    Button("Clear") {
                        draft.file = nil
                        draft.text = ""
                    }
                    .disabled(draft.file == nil && draft.text.isEmpty)
                }
            }
            WorkspaceSection("Output", palette: palette) {
                if input.usesFileExport, let file = input.file {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This file is converted directly to disk.").foregroundStyle(.secondary)
                        Button("Export…", systemImage: "square.and.arrow.up") { export(input, file: file) }
                            .disabled(exportTask != nil)
                    }
                } else if outputInput != input && (input.file != nil || !input.text.isEmpty) {
                    ProgressView("Converting…").controlSize(.small)
                } else if let error, outputInput == input {
                    Text(error).foregroundStyle(.red)
                } else if let result, outputInput == input {
                    if let text = result.text {
                        let preview = text.prefix(20_000)
                        ScrollView([.horizontal, .vertical]) {
                            Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .padding(8)
                        }
                        .frame(minHeight: 100, idealHeight: 170, maxHeight: 240)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                        if preview.endIndex != text.endIndex {
                            Text("Preview limited to 20,000 characters. Copy and export include the full result.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("\(result.data.count.formatted()) bytes of binary data", systemImage: "doc")
                    }
                    HStack {
                        if let text = result.text {
                            Button("Copy", systemImage: "doc.on.doc") { DeveloperToolFiles.copy(text) }
                        }
                        Button("Export…", systemImage: "square.and.arrow.up") {
                            if let file = input.file {
                                export(input, file: file, filename: result.filename)
                            } else {
                                do { try DeveloperToolFiles.save(result.data, as: result.filename) }
                                catch { exportError = error.localizedDescription }
                            }
                        }
                        .disabled(exportTask != nil)
                    }
                } else {
                    Text("Enter text or open a file to convert.").foregroundStyle(.secondary)
                }
                if exportTask != nil {
                    HStack {
                        ProgressView("Converting…").controlSize(.small)
                        Button("Cancel", action: cancelExport)
                    }
                }
                if let exportedFile {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exportedFile]) }
                }
                if let exportError { Text(exportError).foregroundStyle(.red).font(.callout) }
            }
        }
        .task(id: input) {
            cancelExport()
            exportedFile = nil
            result = nil
            error = nil
            exportError = nil
            guard !input.usesFileExport, input.file != nil || !input.text.isEmpty else {
                outputInput = input
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let output = try await input.convert()
                if !Task.isCancelled {
                    result = output
                    outputInput = input
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    outputInput = input
                }
            }
        }
        .onDisappear(perform: cancelExport)
    }

    private func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
    }

    private func export(_ input: Input, file: URL, filename: String? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename ?? (input.decoding ? "decoded.bin" : "encoded.txt")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportError = nil
        exportedFile = nil
        exportTask = Task {
            do {
                try await input.format.convertFile(file, to: destination, decoding: input.decoding,
                                                   padded: input.padded, wrapAt: input.lineWidth)
                if !Task.isCancelled { exportedFile = destination }
            } catch {
                if !Task.isCancelled { exportError = error.localizedDescription }
            }
            if !Task.isCancelled { exportTask = nil }
        }
    }
}
