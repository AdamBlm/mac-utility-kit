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
        Button(onPasteImage != nil ? "Paste" : allowsMultiple ? "Paste Files" : "Paste File", systemImage: "clipboard", action: paste)
        .onPasteCommand(of: onPasteImage == nil ? [.fileURL] : [.fileURL, .image]) { _ in paste() }
        .alert("Paste from Clipboard", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
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
