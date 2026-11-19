import AppKit
import PDFKit
import SwiftUI
import UtilityCore
import UniformTypeIdentifiers

struct PDFProtectionView: View {
    let tool: Tool
    @Binding var input: URL?
    let stageClipboardPDF: (Data) throws -> URL
    @State private var options = PDFProtectionOptions()
    @State private var verifiedPreview: PDFView?
    @State private var task: Task<Void, Never>?
    @State private var savedOutput: URL?
    @State private var issue: String?

    private var removesPassword: Bool { tool == .removePassword }
    private var canExport: Bool {
        guard input != nil, options.executable != nil, task == nil else { return false }
        if removesPassword { return verifiedPreview != nil }
        return !options.password.isEmpty && options.password == options.confirmation
            && (options.ownerPassword.isEmpty || options.password != options.ownerPassword)
    }

    var body: some View {
        InteractiveToolLayout(tool: tool) { palette in
            WorkspaceSection("Document", palette: palette) {
                HStack {
                    if let input { Text(input.lastPathComponent).lineLimit(1) }
                    Button(input == nil ? "Choose PDF…" : "Replace PDF…", systemImage: "folder", action: choosePDF)
                    ClipboardFileButton(allowedTypes: [.pdf], onPastePDF: { data in
                        setInput(try stageClipboardPDF(data))
                    }, onPasteFile: setInput)
                }
                executablePicker("qpdf", selection: $options.executable)
            }
            .disabled(task != nil)
            if input != nil {
                WorkspaceSection("Password", palette: palette) {
                    SecureField("Document password", text: $options.password)
                    if removesPassword {
                        Button("Preview Unlocked PDF", systemImage: "lock.open", action: unlockPreview)
                        if let verifiedPreview, let document = verifiedPreview.document {
                            Text("\(document.pageCount) pages").font(.callout).foregroundStyle(.secondary)
                            PDFReaderCanvas(view: verifiedPreview)
                                .id(ObjectIdentifier(verifiedPreview))
                                .frame(height: 320)
                                .accessibilityLabel("Unlocked PDF preview")
                        }
                    } else {
                        SecureField("Confirm document password", text: $options.confirmation)
                        SecureField("Owner password (optional)", text: $options.ownerPassword)
                        Toggle("Allow printing", isOn: $options.allowsPrinting)
                        Toggle("Allow copying text and images", isOn: $options.allowsCopying)
                        Text("PDF viewers enforce these permissions. Leave the owner password blank to generate one.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .disabled(task != nil)
                Button("Export PDF…", systemImage: "square.and.arrow.up", action: export)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport)
            }
            if task != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { task?.cancel() }
                }
            }
            if let issue { Text(issue).font(.callout).foregroundStyle(.red) }
            if let savedOutput {
                WorkspaceSection("Saved PDF", palette: palette) {
                    Text(savedOutput.lastPathComponent).textSelection(.enabled)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedOutput]) }
                }
            }
        }
        .onChange(of: options.password) { verifiedPreview = nil }
        .onChange(of: input) { resetInputState() }
        .onDisappear {
            task?.cancel()
            clearPasswords()
        }
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setInput(url)
    }

    private func setInput(_ url: URL) {
        input = url
        resetInputState()
    }

    private func resetInputState() {
        savedOutput = nil
        issue = nil
        clearPasswords()
    }

    private func unlockPreview() {
        issue = nil
        verifiedPreview = nil
        guard let input, let document = PDFDocument(url: input), document.isEncrypted,
              document.unlock(withPassword: options.password), document.pageCount > 0 else {
            issue = "Could not unlock this PDF. Check the document and its password."
            return
        }
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.document = document
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
        verifiedPreview = view
    }

    private func export() {
        guard canExport, let input else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = input.deletingPathExtension().lastPathComponent
            + (removesPassword ? " - Unlocked.pdf" : " - Protected.pdf")
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let request = options
        issue = nil
        task = Task {
            defer { task = nil }
            do {
                if removesPassword {
                    _ = try await PDFProtection.remove(input, to: output, options: request)
                } else {
                    _ = try await PDFProtection.add(input, to: output, options: request)
                }
                savedOutput = output
                clearPasswords()
            } catch is CancellationError {
                return
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    private func clearPasswords() {
        options.password = ""
        options.confirmation = ""
        options.ownerPassword = ""
        verifiedPreview = nil
    }
}
