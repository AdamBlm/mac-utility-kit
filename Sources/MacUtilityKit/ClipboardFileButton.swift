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
            Button("Paste Image", systemImage: "clipboard", action: paste)
                .background(ImagePasteShortcut(isEnabled: isEnabled, action: paste))
        } else {
            Button(allowsMultiple ? "Paste Files" : "Paste File", systemImage: "clipboard", action: paste)
                .onPasteCommand(of: [.fileURL]) { _ in paste() }
        }
    }

    private func paste() {
        guard isEnabled else { return }
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
                    message = onPasteImage == nil
                        ? "Copy a supported file in Finder, then try again."
                        : "Copy an image or a supported file, then try again."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// Routes image paste for the current window even when the file button lacks focus.
private struct ImagePasteShortcut: NSViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }

    func updateNSView(_ view: ShortcutView, context: Context) {
        view.action = isEnabled ? action : nil
    }

    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stopMonitoring() }

    final class ShortcutView: NSView {
        var action: (() -> Void)?
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
            if !event.isARepeat { action() }
            return true
        }
    }
}
