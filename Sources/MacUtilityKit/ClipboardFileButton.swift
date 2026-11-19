import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ClipboardFileButton: View {
    let allowedTypes: [UTType]
    let allowsMultiple: Bool
    let onPasteImage: ((CGImage) throws -> Void)?
    let onPaste: ([URL]) -> Void
    @State private var message: String?
    @Environment(\.isEnabled) private var isEnabled

    init(allowedTypes: [UTType], allowsMultiple: Bool = true,
         onPasteImage: ((CGImage) throws -> Void)? = nil, onPaste: @escaping ([URL]) -> Void) {
        self.allowedTypes = allowedTypes
        self.allowsMultiple = allowsMultiple
        self.onPaste = onPaste
        self.onPasteImage = onPasteImage
    }

    init(allowedTypes: [UTType], onPasteImage: ((CGImage) throws -> Void)? = nil,
         onPasteFile: @escaping (URL) -> Void) {
        self.init(allowedTypes: allowedTypes, allowsMultiple: false, onPasteImage: onPasteImage) { urls in
            if let file = urls.first { onPasteFile(file) }
        }
    }

    var body: some View {
        pasteButton
        .background(ClipboardPasteShortcut(isEnabled: isEnabled) { paste(reportsMissingInput: false) })
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
        if onPasteImage != nil {
            Button("Paste Image", systemImage: "clipboard") { paste() }
        } else {
            Button(allowsMultiple ? "Paste Files" : "Paste File", systemImage: "clipboard") { paste() }
                .onPasteCommand(of: [.fileURL]) { _ in paste() }
        }
    }

    @discardableResult
    private func paste(reportsMissingInput: Bool = true) -> Bool {
        guard isEnabled else { return false }
        let board = NSPasteboard.general
        let files = ClipboardFiles.read(from: board, allowedTypes: allowedTypes)
        if !allowsMultiple && files.count > 1 {
            message = "Copy one supported file in Finder, then try again."
        } else if !files.isEmpty {
            onPaste(files)
        } else {
            do {
                if let onPasteImage, let image = try ClipboardFiles.readImage(from: board) {
                    try onPasteImage(image)
                } else {
                    guard reportsMissingInput else { return false }
                    message = onPasteImage == nil
                        ? "Copy a supported file in Finder, then try again."
                        : "Copy an image or a supported file, then try again."
                }
            } catch {
                message = error.localizedDescription
            }
        }
        return true
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
