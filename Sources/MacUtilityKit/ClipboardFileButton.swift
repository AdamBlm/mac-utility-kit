import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct ClipboardFileButton: View {
    let allowedTypes: [UTType]
    let allowsMultiple: Bool
    let onPaste: ([URL]) -> Void
    @State private var message: String?

    init(allowedTypes: [UTType], allowsMultiple: Bool = true, onPaste: @escaping ([URL]) -> Void) {
        self.allowedTypes = allowedTypes
        self.allowsMultiple = allowsMultiple
        self.onPaste = onPaste
    }

    init(allowedTypes: [UTType], onPasteFile: @escaping (URL) -> Void) {
        self.init(allowedTypes: allowedTypes, allowsMultiple: false) { urls in
            if let file = urls.first { onPasteFile(file) }
        }
    }

    var body: some View {
        Button(allowsMultiple ? "Paste Files" : "Paste File", systemImage: "clipboard") {
            let files = ClipboardFiles.read(from: .general, allowedTypes: allowedTypes)
            if files.isEmpty {
                message = "Copy a supported file in Finder, then try again."
            } else if !allowsMultiple && files.count > 1 {
                message = "Copy one supported file in Finder, then try again."
            } else {
                onPaste(files)
            }
        }
        .alert("Paste from Clipboard", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}
