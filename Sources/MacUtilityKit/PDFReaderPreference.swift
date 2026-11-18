import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFReaderPreference: View {
    @State private var reader: URL?
    @State private var changing = false
    @State private var issue: String?

    private var app: URL { Bundle.main.bundleURL.resolvingSymlinksInPath() }

    var body: some View {
        if let reader {
            LabeledContent("Default reader", value: FileManager.default.displayName(atPath: reader.path))
        }
        Button("Make Mac Utility Kit the Default PDF Reader") {
            changing = true
            issue = nil
            Task {
                defer {
                    changing = false
                    refresh()
                }
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .pdf)
                } catch {
                    issue = error.localizedDescription
                }
            }
        }
        .disabled(changing || app.pathExtension != "app" || reader == app)
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        if let issue { Text(issue).foregroundStyle(.secondary) }
    }

    private func refresh() {
        reader = NSWorkspace.shared.urlForApplication(toOpen: UTType.pdf)?.resolvingSymlinksInPath()
    }
}
