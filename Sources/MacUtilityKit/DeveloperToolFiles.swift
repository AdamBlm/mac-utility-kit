import AppKit
import UniformTypeIdentifiers

enum DeveloperToolFiles {
    @MainActor
    static func choose(allowedTypes: [UTType] = [.data]) -> URL? {
        let dialog = NSOpenPanel()
        dialog.allowedContentTypes = allowedTypes
        return dialog.runModal() == .OK ? dialog.url : nil
    }

    static func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }

    @MainActor
    static func save(_ data: Data, as filename: String) throws {
        let dialog = NSSavePanel()
        dialog.nameFieldStringValue = filename
        if dialog.runModal() == .OK, let url = dialog.url {
            try data.write(to: url, options: .atomic)
        }
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func utf8(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
