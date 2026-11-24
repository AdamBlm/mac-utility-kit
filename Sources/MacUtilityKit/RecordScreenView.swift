import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct RecordScreenView: View {
    @Bindable var controller: ScreenRecordingController
    @State private var confirmingDiscard = false
    @State private var preview: ScreenRecordingFile?
    @State private var player = AVPlayer()

    var body: some View {
        InteractiveToolLayout(tool: .recordScreen) { palette in
            if controller.permission {
                WorkspaceSection("Source", palette: palette) { sourceControls }
                WorkspaceSection("Recording settings", palette: palette) { recordingSettings }
            } else {
                WorkspaceSection("Screen access", palette: palette) {
                    Text("Allow screen recording to choose a display, window, or area.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Allow Screen Recording…") { controller.requestAccess() }
                        Button("Open System Settings") { ScreenCapturePermission.openSettings() }
                    }
                }
            }
            WorkspaceSection("Recording", palette: palette) {
                HStack {
                    transport
                    Spacer()
                    Text(time(controller.duration)).monospacedDigit().font(.callout)
                        .accessibilityLabel("Recorded duration \(time(controller.duration))")
                }
                if let geometry = controller.geometry {
                    Text("\(geometry.width) × \(geometry.height) pixels")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let issue = controller.issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            }
            if !controller.files.isEmpty && controller.phase == .ready {
                WorkspaceSection("Completed recording", palette: palette) { completed }
            }
        }
        .task { await controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refresh() }
        }
        .onChange(of: controller.phase) {
            if controller.phase != .ready { closePreview() }
        }
        .onChange(of: controller.files) {
            if let preview, !controller.files.contains(preview) { closePreview() }
        }
        .onDisappear { closePreview() }
        .confirmationDialog("Discard the local recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                closePreview()
                controller.discard()
            }
        }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingRow("Capture") {
                Picker("Capture", selection: $controller.settings.kind) {
                    ForEach(ScreenRecordingSettings.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            switch controller.settings.kind {
            case .display:
                picker("Display", sources: controller.sources?.displays ?? [], selection: $controller.settings.displayID)
            case .window:
                picker("Window", sources: controller.sources?.windows ?? [], selection: $controller.settings.windowID)
            case .region:
                SettingRow("Region") {
                    Button("Select Region…", systemImage: "rectangle.dashed") { controller.selectRegion() }
                    if case .region(_, let area) = controller.settings.region {
                        Text("\(Int(area.width)) × \(Int(area.height)) pt").monospacedDigit()
                    }
                }
            }
        }
        .disabled(controller.phase != .ready)
    }

    private func picker(_ label: String, sources: [ScreenshotSources.Source], selection: Binding<UInt32?>) -> some View {
        SettingRow(label) {
            Picker(label, selection: selection) {
                Text("Choose \(label.lowercased())").tag(UInt32?.none)
                if let id = selection.wrappedValue, !sources.contains(where: { $0.id == id }) {
                    Text("\(label) unavailable").tag(Optional(id))
                }
                ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            Button("Refresh sources", systemImage: "arrow.clockwise") { Task { await controller.refresh() } }
                .labelStyle(.iconOnly)
        }
    }

    private var recordingSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingRow("Resolution") {
                Picker("Resolution", selection: $controller.settings.resolution) {
                    ForEach(ScreenRecordingResolution.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            SettingRow("Frame rate") {
                Picker("Frame rate", selection: $controller.settings.frameRate) {
                    ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            SettingRow("Countdown") {
                Picker("Countdown", selection: $controller.settings.countdown) {
                    Text("Off").tag(0)
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Toggle("Include system audio", isOn: $controller.settings.capturesSystemAudio)
            Toggle("Include microphone audio", isOn: $controller.settings.capturesMicrophone)
            if controller.settings.capturesMicrophone {
                SettingRow("Microphone") {
                    Picker("Microphone", selection: $controller.settings.microphoneID) {
                        Text("System default").tag(String?.none)
                        if let id = controller.settings.microphoneID,
                           !controller.microphones.contains(where: { $0.id == id }) {
                            Text("Disconnected microphone").tag(Optional(id))
                        }
                        ForEach(controller.microphones) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }
            }
            Toggle("Show mouse clicks", isOn: $controller.settings.showsClicks)
        }
        .disabled(controller.phase != .ready)
    }

    @ViewBuilder
    private var transport: some View {
        switch controller.phase {
        case .ready:
            Button("Record Screen", systemImage: "record.circle") { controller.start() }
                .buttonStyle(.borderedProminent).disabled(!controller.canStart)
        case .selecting:
            Text("Select a region on the display.").font(.callout)
        case .authorizing:
            ProgressView("Checking permissions…").controlSize(.small)
        case .countdown(let seconds):
            Text("Recording starts in \(seconds)…").font(.callout.monospacedDigit())
            Button("Cancel") { controller.stop() }
        case .starting:
            ProgressView("Starting recording…").controlSize(.small)
            Button("Cancel") { controller.stop() }
        case .recording:
            Button("Stop", systemImage: "stop.fill") { controller.stop() }.buttonStyle(.borderedProminent)
            Button("Pause", systemImage: "pause.fill") { controller.pause() }
        case .pausing:
            ProgressView("Saving segment…").controlSize(.small)
        case .paused:
            Button("Resume", systemImage: "play.fill") { controller.resume() }.buttonStyle(.borderedProminent)
            Button("Stop", systemImage: "stop.fill") { controller.stop() }
        case .finishing:
            ProgressView("Finalizing recording…").controlSize(.small)
        }
    }

    private var completed: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(controller.files.enumerated()), id: \.element.id) { index, file in
                HStack {
                    let label = controller.files.count > 1 ? "Segment \(index + 1)" : "Screen Recording"
                    let name = controller.saved[file.url]?.lastPathComponent ?? label
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).lineLimit(1)
                        Text("\(time(file.duration)) · \(Int(file.dimensions.width)) × \(Int(file.dimensions.height)) · MP4")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if preview == file {
                        Button("Hide Preview", systemImage: "xmark") { closePreview() }
                    } else {
                        Button("Preview", systemImage: "play.rectangle") { play(file) }
                    }
                    Button("Save MP4…", systemImage: "square.and.arrow.down") { save(file, name: label) }
                        .disabled(controller.saving)
                }
            }
            if preview != nil {
                VideoPreviewPlayer(player: player)
                    .accessibilityLabel("Screen recording preview")
            }
            if controller.canStart == false && controller.files.contains(where: { controller.saved[$0.url] == nil }) {
                Text("Save or discard these files before starting another recording.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Discard Recording…", systemImage: "trash", role: .destructive) { confirmingDiscard = true }
                .disabled(controller.saving)
        }
    }

    private func save(_ file: ScreenRecordingFile, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = name + ".mp4"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        Task { await controller.save(file, to: output) }
    }

    private func play(_ file: ScreenRecordingFile) {
        closePreview()
        preview = file
        player.replaceCurrentItem(with: AVPlayerItem(url: file.url))
        player.play()
    }

    private func closePreview() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        preview = nil
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 1)))
    }
}
