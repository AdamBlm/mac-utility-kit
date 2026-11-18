import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct RecordAudioView: View {
    let controller: AudioRecordingController
    var onTranscribe: (URL) -> Void
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var playbackIssue: String?
    @State private var confirmsDiscard = false

    var body: some View {
        InteractiveToolLayout(tool: .recordAudio) { palette in
            WorkspaceSection("Microphone", palette: palette) {
                SettingRow("Input") {
                    Picker("Microphone", selection: Binding(
                        get: { controller.selectedDeviceID }, set: { controller.selectedDeviceID = $0 }
                    )) {
                        Text("System default").tag(String?.none)
                        if let id = controller.selectedDeviceID, !controller.selectedDeviceIsAvailable {
                            Text("Disconnected microphone").tag(Optional(id))
                        }
                        ForEach(controller.devices) { device in Text(device.name).tag(Optional(device.id)) }
                    }
                    .labelsHidden()
                    .disabled(controller.phase != .ready)
                    Button("Refresh microphones", systemImage: "arrow.clockwise") { controller.refreshDevices() }
                        .labelStyle(.iconOnly)
                }
                if !controller.selectedDeviceIsAvailable {
                    Text("Choose a connected microphone.").font(.callout).foregroundStyle(.secondary)
                }
            }

            WorkspaceSection("Recording", palette: palette) {
                meter
                HStack {
                    controls
                    Spacer()
                    Text(time(controller.duration)).font(.callout.monospacedDigit())
                        .accessibilityLabel("Recorded duration \(time(controller.duration))")
                }
                if let issue = controller.issue {
                    Text(issue).font(.callout).foregroundStyle(.secondary)
                }
            }

            if let recording = controller.recording {
                WorkspaceSection("Completed recording", palette: palette) {
                    completed(recording)
                    if let playbackIssue { Text(playbackIssue).font(.callout).foregroundStyle(.red) }
                }
            }
        }
        .task { controller.refreshDevices() }
        .task(id: playing) { await trackPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            controller.refreshDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            controller.refreshDevices()
        }
        .onChange(of: controller.recording) {
            stopPlayback()
            playbackIssue = nil
        }
        .onDisappear { stopPlayback() }
        .confirmationDialog("Discard this recording?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                stopPlayback()
                controller.discard()
            }
        }
    }

    private var meter: some View {
        let level = controller.level
        let color: Color = level.isNearClipping ? .red : (level.peakDB > -6 ? .orange : .accentColor)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input level").font(.callout)
                Spacer()
                Text(level.averageDB <= -60 ? "−∞ dBFS" : "\(Int(level.averageDB.rounded())) dBFS")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: level.meterFraction)
                .tint(color)
                .accessibilityLabel("Microphone level")
            if level.isNearClipping {
                Label("Input peaks near clipping", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch controller.phase {
        case .ready:
            Button("Record", systemImage: "record.circle") {
                stopPlayback()
                controller.start()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canStart || !controller.selectedDeviceIsAvailable)
        case .authorizing:
            ProgressView("Waiting for microphone access…").controlSize(.small)
        case .starting:
            ProgressView("Starting recording…").controlSize(.small)
            Button("Cancel") { controller.stop() }
        case .recording, .paused:
            Button("Stop", systemImage: "stop.fill") { controller.stop() }
                .buttonStyle(.borderedProminent)
            if controller.phase == .recording {
                Button("Pause", systemImage: "pause.fill") { controller.pause() }
            } else {
                Button("Resume", systemImage: "play.fill") { controller.resume() }
            }
        case .finishing:
            ProgressView("Finalizing recording…").controlSize(.small)
        }
    }

    private func completed(_ recording: AudioRecordingFile) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let location = controller.savedURL {
                Text(location.lastPathComponent).lineLimit(1).help(location.path)
                    .foregroundStyle(.secondary)
            } else {
                Text("Save or discard this recording before starting another.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                    preview(recording)
                }
                Button("Save Recording…", systemImage: "square.and.arrow.down") { save(thenTranscribe: false) }
                    .disabled(controller.isSaving)
                Button("Send to Transcribe", systemImage: "waveform") {
                    if let location = controller.savedURL, FileManager.default.fileExists(atPath: location.path) {
                        stopPlayback()
                        onTranscribe(location)
                    } else {
                        save(thenTranscribe: true)
                    }
                }
                .disabled(controller.isSaving)
                Button("Discard Recording…", systemImage: "trash", role: .destructive) {
                    confirmsDiscard = true
                }
                .labelStyle(.iconOnly)
                .disabled(controller.isSaving)
                if controller.isSaving { ProgressView().controlSize(.small) }
            }
        }
    }

    private func save(thenTranscribe: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = "Recording.m4a"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            if await controller.save(to: destination), thenTranscribe {
                stopPlayback()
                onTranscribe(destination)
            }
        }
    }

    private func preview(_ recording: AudioRecordingFile) {
        playbackIssue = nil
        if playing {
            player?.pause()
            playing = false
            return
        }
        do {
            if player == nil { player = try AVAudioPlayer(contentsOf: recording.url) }
            playing = player?.play() == true
            if !playing { playbackIssue = "Could not play the recording." }
        } catch {
            playbackIssue = error.localizedDescription
        }
    }

    private func trackPlayback() async {
        while playing, !Task.isCancelled {
            if player?.isPlaying != true { stopPlayback(); return }
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playing = false
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(seconds)
            .formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 1)))
    }
}
