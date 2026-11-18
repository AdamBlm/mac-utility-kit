import AppKit
import SwiftUI
import UtilityCore
import UniformTypeIdentifiers

enum ScreenshotMode: String, CaseIterable, Identifiable {
    case region = "Region"
    case display = "Display"
    case window = "Window"
    case scrolling = "Scrolling"

    var id: Self { self }
}

struct ScreenshotDraft {
    var mode = ScreenshotMode.region
    var delay = 0
    var showsCursor = false
    var format = ScreenshotOutputFormat.png
    var displayID: UInt32?
    var windowID: UInt32?
    var scrollingWindowID: UInt32?
    var topTrim = 0
    var bottomTrim = 0
    var image: CGImage?
    var seams: [Int] = []
}

struct ScreenshotView: View {
    @Binding var draft: ScreenshotDraft
    var onAnnotate: ((CGImage) -> Void)?

    @State private var selector = ScreenRegionSelector()
    @State private var listings: ScreenshotSources.Listings?
    @State private var task: Task<Void, Never>?
    @State private var scrolling: ScrollingScreenshot?
    @State private var countdown: Int?
    @State private var message: String?
    @State private var permissionNeeded = false
    @State private var showsSeams = false

    var body: some View {
        InteractiveToolLayout(tool: .screenshot) { palette in
            WorkspaceSection("Capture", palette: palette) {
                SettingRow("Mode") {
                    Picker("Capture mode", selection: $draft.mode) {
                        ForEach(ScreenshotMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                .disabled(task != nil || scrolling != nil)
                if draft.mode != .region { sourcePicker }
                if draft.mode == .scrolling { scrollingControls }
                SettingRow("Countdown") {
                    Picker("Countdown", selection: $draft.delay) {
                        Text("None").tag(0)
                        ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    .labelsHidden()
                }
                .disabled(task != nil)
                if draft.mode != .scrolling {
                    Toggle("Include cursor", isOn: $draft.showsCursor).disabled(task != nil)
                }
                captureActions
                if permissionNeeded {
                    Text("Allow Mac Utility Kit in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open System Settings", systemImage: "gear", action: ScreenCapturePermission.openSettings)
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            if let image = draft.image { result(image, palette: palette) }
        }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        let windows = listings?.windows ?? []
        let sources: [ScreenshotSources.Source] = switch draft.mode {
        case .region: []
        case .display: listings?.displays ?? []
        case .window: windows
        case .scrolling: windows.filter { !$0.isUtilityWindow }
        }
        let selected = switch draft.mode {
        case .display: $draft.displayID
        case .scrolling: $draft.scrollingWindowID
        default: $draft.windowID
        }
        let title = draft.mode == .display ? "Display" : "Window"
        SettingRow(title) {
            if !sources.isEmpty {
                Picker(title, selection: selected) {
                    Text("Choose " + title.lowercased()).tag(UInt32?.none)
                    ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            }
            Button(listings == nil ? "Load Sources…" : "Refresh", systemImage: "arrow.clockwise", action: loadSources)
        }
        .disabled(task != nil || scrolling != nil)
    }

    @ViewBuilder
    private var scrollingControls: some View {
        Text("Scroll down in the selected window between captures. Keep some of the previous view visible.")
            .font(.callout).foregroundStyle(.secondary)
        SettingRow("Trim fixed edges") {
            TextField("Top", value: $draft.topTrim, format: .number)
                .frame(width: 64).accessibilityLabel("Top margin in pixels")
            TextField("Bottom", value: $draft.bottomTrim, format: .number)
                .frame(width: 64).accessibilityLabel("Bottom margin in pixels")
            Text("px").foregroundStyle(.secondary)
        }
        .disabled(task != nil || scrolling != nil)
        if let scrolling {
            Text("\(scrolling.seamRows.count + 1) captured frames")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var captureActions: some View {
        HStack {
            Button(captureTitle, systemImage: "camera.viewfinder", action: startCapture)
                .buttonStyle(.borderedProminent)
                .disabled(task != nil || !hasSource)
            if scrolling != nil {
                Button("Finish Capture") { scrolling = nil }
                    .disabled(task != nil)
            }
            if task != nil {
                if let countdown {
                    Text("\(countdown)").monospacedDigit().accessibilityLabel("\(countdown) seconds to capture")
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { task?.cancel() }
            }
        }
    }

    private var hasSource: Bool {
        switch draft.mode {
        case .region: true
        case .display: draft.displayID != nil
        case .window: draft.windowID != nil
        case .scrolling: draft.scrollingWindowID != nil
        }
    }

    private var captureTitle: String {
        switch draft.mode {
        case .region: "Select Region"
        case .display, .window: "Capture"
        case .scrolling: scrolling == nil ? "Start Scrolling Capture" : "Add Frame"
        }
    }

    private func result(_ image: CGImage, palette: WorkspacePalette) -> some View {
        WorkspaceSection("Preview", palette: palette) {
            if !draft.seams.isEmpty {
                Toggle("Show seams", isOn: $showsSeams)
            }
            ScrollView([.horizontal, .vertical]) {
                GeometryReader { geometry in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            if showsSeams {
                                ForEach(draft.seams, id: \.self) { row in
                                    Rectangle().fill(palette.accent.opacity(0.9))
                                        .frame(height: 1)
                                        .offset(y: geometry.size.height * CGFloat(row) / CGFloat(image.height))
                                }
                            }
                        }
                        .accessibilityLabel("Screenshot preview")
                }
                .frame(width: min(360, CGFloat(image.width)), height: previewHeight(image))
            }
            .frame(maxHeight: 450)
            Text("\(image.width) × \(image.height) pixels").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            SettingRow("Format") {
                Picker("Export format", selection: $draft.format) {
                    ForEach(ScreenshotOutputFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Button("Copy", systemImage: "doc.on.doc") { copy(image) }
                Button("Export…", systemImage: "square.and.arrow.up") { save(image) }
                if let onAnnotate {
                    Button("Annotate", systemImage: "pencil.tip") { onAnnotate(image) }
                }
                Spacer()
                Button("Clear") {
                    draft.image = nil
                    draft.seams = []
                    scrolling = nil
                    message = nil
                }
            }
        }
        .disabled(task != nil)
    }

    private func previewHeight(_ image: CGImage) -> CGFloat {
        min(360, CGFloat(image.width)) * CGFloat(image.height) / CGFloat(image.width)
    }

    private func requestAccess() -> Bool {
        permissionNeeded = !ScreenCapturePermission.request()
        return !permissionNeeded
    }

    private func loadSources() {
        guard task == nil, requestAccess() else { return }
        message = nil
        task = Task {
            defer { task = nil }
            do {
                let loaded = try await ScreenshotSources.list()
                try Task.checkCancellation()
                listings = loaded
                if !loaded.displays.contains(where: { $0.id == draft.displayID }) { draft.displayID = loaded.displays.first?.id }
                if !loaded.windows.contains(where: { $0.id == draft.windowID }) { draft.windowID = loaded.windows.first?.id }
                let scrollWindows = loaded.windows.filter { !$0.isUtilityWindow }
                if !scrollWindows.contains(where: { $0.id == draft.scrollingWindowID }) {
                    draft.scrollingWindowID = scrollWindows.first?.id
                }
            } catch is CancellationError {
                return
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func startCapture() {
        guard task == nil, hasSource, requestAccess() else { return }
        message = nil
        task = Task {
            defer {
                task = nil
                countdown = nil
            }
            do {
                if draft.mode == .scrolling {
                    try await addScrollingFrame()
                } else if let captured = try await captureImage() {
                    try Task.checkCancellation()
                    draft.image = captured
                    draft.seams = []
                }
            } catch is CancellationError {
                return
            } catch {
                permissionNeeded = !CGPreflightScreenCaptureAccess()
                message = error.localizedDescription
            }
        }
    }

    private func captureImage() async throws -> CGImage? {
        switch draft.mode {
        case .region:
            guard let selected = await selector.select() else { return nil }
            try await Task.sleep(for: .milliseconds(120))
            try await runCountdown()
            return try await ScreenImageCapture.capture(region: selected.region, displays: selected.displays,
                        maximumEdge: nil, showsCursor: draft.showsCursor, prefersNativeMultiDisplayCapture: false)
        case .display:
            guard let id = draft.displayID else { return nil }
            try await runCountdown()
            return try await ScreenshotSources.display(id, showsCursor: draft.showsCursor)
        case .window:
            guard let id = draft.windowID else { return nil }
            try await runCountdown()
            return try await ScreenshotSources.window(id, showsCursor: draft.showsCursor)
        case .scrolling:
            return nil
        }
    }

    private func addScrollingFrame() async throws {
        guard let id = draft.scrollingWindowID else { return }
        try await runCountdown()
        let captured = try await ScreenshotSources.window(id, showsCursor: false)
        let previous = scrolling
        let top = draft.topTrim
        let bottom = draft.bottomTrim
        let work = Task.detached(priority: .userInitiated) {
            let trimmed = try ScrollingScreenshot.trim(captured, top: top, bottom: bottom)
            return try previous?.adding(trimmed) ?? ScrollingScreenshot(trimmed)
        }
        let updated = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        scrolling = updated
        draft.image = updated.image
        draft.seams = updated.seamRows
    }

    private func runCountdown() async throws {
        if draft.delay <= 0 { return }
        for seconds in stride(from: draft.delay, through: 1, by: -1) {
            countdown = seconds
            try await Task.sleep(for: .seconds(1))
        }
        countdown = nil
    }

    private func copy(_ image: CGImage) {
        do {
            let data = try ScreenshotImageOutput.encode(image, format: draft.format)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let type: NSPasteboard.PasteboardType = draft.format == .png ? .png : .init(UTType.jpeg.identifier)
            if pasteboard.setData(data, forType: type) {
                message = "Copied screenshot."
            } else {
                message = "Could not copy the screenshot."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func save(_ image: CGImage) {
        do {
            let data = try ScreenshotImageOutput.encode(image, format: draft.format)
            try DeveloperToolFiles.save(data, as: "Screenshot." + draft.format.fileExtension)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
