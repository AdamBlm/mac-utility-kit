import AppKit
import ImageIO
import SwiftUI
import UtilityCore
import UniformTypeIdentifiers

struct ClipboardHistoryView: View {
    let controller: ClipboardHistoryController
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var excludedIdentifier = ""
    @State private var message: String?

    enum Filter: String, CaseIterable { case all = "All", text = "Text", images = "Images", pinned = "Pinned" }

    var body: some View {
        InteractiveToolLayout(tool: .clipboardHistory) { palette in
            WorkspaceSection("Recording", palette: palette) {
                HStack {
                    switch controller.status {
                    case .disabled: Button("Enable history", action: controller.start)
                    case .paused: Button("Resume recording", action: controller.start)
                    case .recording: Button("Pause recording", action: controller.pause)
                    }
                    if controller.status != .disabled {
                        Button("Disable recording", action: controller.disable)
                    }
                    Spacer()
                    Picker("Keep recent entries", selection: Binding(
                        get: { controller.retention },
                        set: { controller.retention = $0 }
                    )) {
                        ForEach([10, 25, 50], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .fixedSize()
                }
                Text("Recording continues while you use other tools. History and exclusions last until you quit. History holds up to 64 MB, including up to 20 pinned items.")
                    .foregroundStyle(.secondary)
            }

            WorkspaceSection("Excluded apps", palette: palette) {
                Text("macOS reports the foreground app when history checks the clipboard. Background copies can be attributed to the wrong app.")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Bundle identifier", text: $excludedIdentifier)
                    Button("Exclude") {
                        controller.exclude(excludedIdentifier)
                        excludedIdentifier = ""
                    }
                    .disabled(excludedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Choose an app…", action: chooseExcludedApp)
                }
                ForEach(controller.excludedApps.sorted(), id: \.self) { identifier in
                    HStack {
                        Text(identifier)
                        Spacer()
                        Button("Remove exclusion") { controller.allow(identifier) }
                    }
                }
            }

            WorkspaceSection("History", palette: palette) {
                HStack {
                    TextField("Search history", text: $search)
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                    Button("Clear unpinned") {
                        controller.clearUnpinned()
                        message = nil
                    }
                    .disabled(!controller.entries.contains { !$0.pinned })
                }
                if let message { Text(message).foregroundStyle(.secondary) }
                if visibleEntries.isEmpty {
                    Text(controller.entries.isEmpty ? "No clipboard entries yet." : "No matching entries.")
                        .foregroundStyle(.secondary)
                }
                ForEach(visibleEntries) { entry in
                    HStack {
                        switch entry.content {
                        case .text(let text):
                            Text(text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        case .image(let data, _):
                            ClipboardHistoryThumbnail(data: data)
                            Text("Image").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let app = entry.foregroundApp {
                            Text(app).foregroundStyle(.secondary).lineLimit(1)
                                .accessibilityLabel("Foreground app: \(app)")
                        }
                        Text(entry.date, style: .time).foregroundStyle(.secondary)
                        Button("Copy") {
                            message = controller.copy(entry) ? "Copied to clipboard." : "Could not copy this entry."
                        }
                        Button(entry.pinned ? "Unpin" : "Pin") { controller.togglePin(entry.id) }
                            .disabled(!entry.pinned && controller.entries.filter(\.pinned).count >= 20)
                        Button("Remove", role: .destructive) { controller.remove(entry.id) }
                    }
                }
            }
        }
    }

    private var visibleEntries: [ClipboardHistoryController.Entry] {
        controller.entries.filter { entry in
            let isImage: Bool
            let searchableValue: String
            switch entry.content {
            case .text(let value):
                isImage = false
                searchableValue = value
            case .image:
                isImage = true
                searchableValue = "Image"
            }
            switch filter {
            case .text where isImage, .images where !isImage, .pinned where !entry.pinned: return false
            default: break
            }
            return search.isEmpty || searchableValue.localizedStandardContains(search)
                || (entry.foregroundApp?.localizedStandardContains(search) ?? false)
        }
    }

    private func chooseExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier
        else { return }
        controller.exclude(identifier)
    }
}

private struct ClipboardHistoryThumbnail: View {
    let data: Data
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 34, height: 28)
        .accessibilityHidden(true)
        .task {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 68,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        }
    }
}
