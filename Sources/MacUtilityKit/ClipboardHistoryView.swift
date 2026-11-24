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
                WorkspaceFlowLayout {
                    switch controller.status {
                    case .disabled:
                        Button("Enable History", action: controller.start)
                            .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                    case .paused:
                        Button("Resume Recording", action: controller.start)
                            .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                    case .recording:
                        Button("Pause Recording", action: controller.pause)
                    }
                    if controller.status != .disabled {
                        Button("Disable Recording", action: controller.disable)
                    }
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
                        .textFieldStyle(.roundedBorder)
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
                        .textFieldStyle(.roundedBorder)
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    Button("Clear Unpinned") {
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
                let pinLimitReached = controller.entries.filter(\.pinned).count >= 20
                ForEach(visibleEntries) { entry in
                    Divider()
                    historyRow(entry, pinLimitReached: pinLimitReached)
                }
            }
        }
    }

    private func historyRow(_ entry: ClipboardHistoryController.Entry, pinLimitReached: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                switch entry.content {
                case .text(let text):
                    Text(text).lineLimit(2)
                case .image(let data, _):
                    HStack {
                        ClipboardHistoryThumbnail(data: data)
                        Text("Image")
                    }
                }
                HStack(spacing: 6) {
                    if let app = entry.foregroundApp {
                        Text(app).lineLimit(1).truncationMode(.middle)
                            .accessibilityLabel("Foreground app: \(app)")
                    }
                    Text(entry.date, style: .time)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Button("Copy", systemImage: "doc.on.doc") {
                    message = controller.copy(entry) ? "Copied to clipboard." : "Could not copy this entry."
                }
                .help("Copy entry")
                Button(entry.pinned ? "Unpin" : "Pin", systemImage: entry.pinned ? "pin.fill" : "pin") {
                    controller.togglePin(entry.id)
                }
                .disabled(!entry.pinned && pinLimitReached)
                .help(entry.pinned ? "Unpin entry" : "Pin entry")
                Button("Remove", systemImage: "trash", role: .destructive) { controller.remove(entry.id) }
                    .help("Remove entry")
            }
            .labelStyle(.iconOnly)
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
