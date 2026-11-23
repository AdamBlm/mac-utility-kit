import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ClipboardFileButton: View {
    let allowedTypes: [UTType]
    let allowsMultiple: Bool
    /// Opt in when the receiver can append several items through separate callbacks.
    let importsItemsIndividually: Bool
    let onPasteImage: ((CGImage) throws -> Void)?
    let onPastePDF: ((Data) throws -> Void)?
    let stagePDF: ((Data) throws -> URL)?
    let stageImage: ((CGImage) throws -> URL)?
    let onPaste: ([URL]) -> Void
    let buttonOnlyTitle: String?
    @State private var message: String?
    @Environment(\.isEnabled) private var isEnabled

    private var acceptsImage: Bool { onPasteImage != nil || stageImage != nil }
    private var acceptsPDF: Bool { onPastePDF != nil || stagePDF != nil }

    init(allowedTypes: [UTType], allowsMultiple: Bool = true, importsItemsIndividually: Bool = false,
         onPasteImage: ((CGImage) throws -> Void)? = nil,
         onPastePDF: ((Data) throws -> Void)? = nil, stagePDF: ((Data) throws -> URL)? = nil,
         stageImage: ((CGImage) throws -> URL)? = nil, buttonOnlyTitle: String? = nil,
         onPaste: @escaping ([URL]) -> Void) {
        self.allowedTypes = allowedTypes
        self.allowsMultiple = allowsMultiple
        self.importsItemsIndividually = importsItemsIndividually
        self.onPaste = onPaste
        self.onPasteImage = onPasteImage
        self.onPastePDF = onPastePDF
        self.stagePDF = stagePDF
        self.stageImage = stageImage
        self.buttonOnlyTitle = buttonOnlyTitle
    }

    init(allowedTypes: [UTType], onPasteImage: ((CGImage) throws -> Void)? = nil,
         onPastePDF: ((Data) throws -> Void)? = nil, buttonOnlyTitle: String? = nil, onPasteFile: @escaping (URL) -> Void) {
        self.init(allowedTypes: allowedTypes, allowsMultiple: false, onPasteImage: onPasteImage,
                  onPastePDF: onPastePDF, buttonOnlyTitle: buttonOnlyTitle) { urls in
            if let file = urls.first { onPasteFile(file) }
        }
    }

    var body: some View {
        pasteButton
        .background(ClipboardPasteShortcut(isEnabled: isEnabled && buttonOnlyTitle == nil) { paste(reportsMissingInput: false) })
        .alert("Paste from Clipboard", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private var pasteButton: some View {
        if let buttonOnlyTitle {
            Button(buttonOnlyTitle, systemImage: "clipboard") { paste() }
        } else if acceptsImage, acceptsPDF {
            Button("Paste Image or PDF", systemImage: "clipboard") { paste() }
                .onPasteCommand(of: [.fileURL, .pdf, .image]) { _ in paste() }
        } else if acceptsImage {
            Button("Paste Image", systemImage: "clipboard") { paste() }
                .onPasteCommand(of: [.fileURL, .image]) { _ in paste() }
        } else if acceptsPDF {
            Button("Paste PDF", systemImage: "clipboard") { paste() }
                .onPasteCommand(of: [.fileURL, .pdf]) { _ in paste() }
        } else {
            Button(allowsMultiple ? "Paste Files" : "Paste File", systemImage: "clipboard") { paste() }
                .onPasteCommand(of: [.fileURL]) { _ in paste() }
        }
    }

    @discardableResult
    private func paste(reportsMissingInput: Bool = true) -> Bool {
        guard isEnabled else { return false }
        return paste(from: .general, reportsMissingInput: reportsMissingInput)
    }

    @discardableResult
    func paste(from board: NSPasteboard, reportsMissingInput: Bool = true) -> Bool {
        if !allowsMultiple || importsItemsIndividually || stagesBatch,
           acceptsImage || acceptsPDF,
           let items = board.pasteboardItems, items.count > 1, pasteItems(items) {
            return true
        }
        let files = ClipboardFiles.read(from: board, allowedTypes: allowedTypes)
        if !allowsMultiple && files.count > 1 {
            message = "Copy one supported file in Finder, then try again."
        } else if !files.isEmpty {
            onPaste(files)
        } else {
            do {
                if acceptsPDF, let data = board.data(forType: .pdf) {
                    if let stagePDF { onPaste([try pastePDF(data, using: stagePDF)]) }
                    else if let onPastePDF { try pastePDF(data, using: onPastePDF) }
                } else if acceptsImage, let image = try ClipboardFiles.readImage(from: board) {
                    if let stageImage { onPaste([try stageImage(image)]) }
                    else { try onPasteImage?(image) }
                } else {
                    guard reportsMissingInput else { return false }
                    if acceptsPDF, acceptsImage {
                        message = "Copy an image, PDF content, or a supported file, then try again."
                    } else if acceptsPDF {
                        message = "Copy PDF content or a PDF file in Finder, then try again."
                    } else {
                        message = acceptsImage
                            ? "Copy an image or a supported file, then try again."
                            : "Copy a supported file in Finder, then try again."
                    }
                }
            } catch {
                message = error.localizedDescription
            }
        }
        return true
    }

    private func pasteItems(_ items: [NSPasteboardItem]) -> Bool {
        var handled = false
        var issues: [String] = []
        var singleInput: ClipboardFiles.Content?
        var batch: [URL] = []
        for (index, item) in items.enumerated() {
            do {
                guard let content = try ClipboardFiles.content(from: item, allowedTypes: allowedTypes,
                                                                acceptsPDF: acceptsPDF,
                                                                acceptsImage: acceptsImage) else { continue }
                handled = true
                if allowsMultiple {
                    try deliver(content, batch: &batch)
                } else {
                    guard singleInput == nil else {
                        message = "Copy one supported item, then try again."
                        return true
                    }
                    singleInput = content
                }
            } catch {
                handled = true
                issues.append("Item \(index + 1) — \(error.localizedDescription)")
            }
        }
        if let singleInput, issues.isEmpty {
            do { try deliver(singleInput, batch: &batch) }
            catch { issues.append(error.localizedDescription) }
        }
        if !batch.isEmpty { onPaste(batch) }
        if !issues.isEmpty { message = issues.joined(separator: "\n") }
        return handled
    }

    private var stagesBatch: Bool { stagePDF != nil || stageImage != nil }

    private func deliver(_ content: ClipboardFiles.Content, batch: inout [URL]) throws {
        switch content {
        case .file(let url):
            if stagesBatch { batch.append(url) }
            else { onPaste([url]) }
        case .pdf(let data):
            if let stagePDF { batch.append(try pastePDF(data, using: stagePDF)) }
            else if let onPastePDF { try pastePDF(data, using: onPastePDF) }
        case .image(let image):
            if let stageImage { batch.append(try stageImage(image)) }
            else { try onPasteImage?(image) }
        }
    }

    private func pastePDF<Result>(_ data: Data, using action: (Data) throws -> Result) throws -> Result {
        guard data.count <= 256 * 1024 * 1024 else {
            throw ToolError.invalid("The copied PDF exceeds 256 MB. Save it to a file and import the file instead.")
        }
        return try action(data)
    }
}

/// Routes clipboard imports for the current window even when the file button lacks focus.
private struct ClipboardPasteShortcut: NSViewRepresentable {
    let isEnabled: Bool
    let action: () -> Bool

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }

    func updateNSView(_ view: ShortcutView, context: Context) {
        view.action = isEnabled ? action : nil
    }

    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stopMonitoring() }

    final class ShortcutView: NSView {
        var action: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handlePaste(event) == true ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handlePaste(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
                  !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let action else { return false }
            return event.isARepeat || action()
        }
    }
}
