import AVFoundation
import Observation
import UtilityCore

@MainActor
@Observable
final class AudioRecordingController {
    enum Phase {
        case ready, authorizing, starting, recording, paused, finishing
    }

    var selectedDeviceID: String?
    private(set) var devices: [AudioCaptureDevice] = []
    private(set) var phase = Phase.ready
    private(set) var level = AudioCaptureLevel.silence
    private(set) var duration = 0.0
    private(set) var recording: AudioRecordingFile?
    private(set) var savedURL: URL?
    private(set) var issue: String?
    private(set) var isSaving = false
    @ObservationIgnored private let engine = AudioCaptureEngine()
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var scratch: URL?

    var canStart: Bool {
        phase == .ready && !isSaving && (recording == nil || savedURL != nil)
    }

    var selectedDeviceIsAvailable: Bool {
        guard let selectedDeviceID else { return true }
        return devices.contains { $0.id == selectedDeviceID }
    }

    func refreshDevices() { devices = AudioCaptureEngine.devices() }

    func start() {
        guard canStart, selectedDeviceIsAvailable else { return }
        // A SwiftPM executable has no microphone usage string. Requesting
        // recording permission there can terminate the process under TCC.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            issue = "Open the Mac Utility Kit app bundle to record audio."
            return
        }
        issue = nil
        phase = .authorizing
        let deviceID = selectedDeviceID
        Task { await authorizeAndStart(deviceID) }
    }

    func pause() {
        guard phase == .recording else { return }
        engine.pause()
    }

    func resume() {
        guard phase == .paused else { return }
        engine.resume()
    }

    func stop() {
        guard phase == .starting || phase == .recording || phase == .paused else { return }
        phase = .finishing
        engine.stop()
    }

    func discard() {
        guard phase == .ready, !isSaving else { return }
        clearPreviousRecording()
        issue = nil
    }

    func save(to destination: URL) async -> Bool {
        guard let recording, phase == .ready, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await recording.save(to: destination)
            savedURL = destination
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }

    private func authorizeAndStart(_ deviceID: String?) async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let approved: Bool
        switch status {
        case .authorized: approved = true
        case .notDetermined: approved = await AVCaptureDevice.requestAccess(for: .audio)
        default: approved = false
        }
        guard approved else {
            issue = status == .restricted
                ? "Access to the microphone is restricted by macOS."
                : "Allow Mac Utility Kit in System Settings › Privacy & Security › Microphone."
            phase = .ready
            return
        }

        do {
            let id = UUID()
            let folder = FileManager.default.temporaryDirectory
                .appending(path: ".MacUtilityKit-Recording-\(id.uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            clearPreviousRecording()
            scratch = folder
            request = id
            phase = .starting
            engine.start(deviceID: deviceID, at: folder.appending(path: "Recording.m4a")) { [weak self] event in
                Task { @MainActor in await self?.receive(event, id: id) }
            }
        } catch {
            issue = error.localizedDescription
            phase = .ready
        }
    }

    private func receive(_ event: AudioCaptureEngine.Event, id: UUID) async {
        guard request == id else { return }
        switch event {
        case .began:
            if phase == .starting { phase = .recording }
        case .paused:
            if phase == .recording { phase = .paused }
        case .resumed:
            if phase == .paused { phase = .recording }
        case .meter(let reading, let elapsed):
            if phase == .recording || phase == .paused {
                level = phase == .recording ? reading : .silence
                duration = max(duration, elapsed)
            }
        case .ending:
            level = .silence
            phase = .finishing
        case .ended(let url, let interruption):
            phase = .finishing
            level = .silence
            do {
                let result = try await AudioRecordingFile.inspect(url)
                recording = result
                duration = result.duration
                if let interruption {
                    issue = "\(interruption) The recorded audio is available to save."
                }
            } catch {
                clearPreviousRecording()
                issue = interruption.map { "\($0) \(error.localizedDescription)" } ?? error.localizedDescription
            }
            request = nil
            phase = .ready
        case .failed(let message):
            clearPreviousRecording()
            request = nil
            phase = .ready
            issue = message
        }
    }

    private func clearPreviousRecording() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        recording = nil
        savedURL = nil
        level = .silence
        duration = 0
    }
}
