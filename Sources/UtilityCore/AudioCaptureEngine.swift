import AVFoundation
import Foundation

public struct AudioCaptureDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
}

public struct AudioCaptureLevel: Equatable, Sendable {
    public let averageDB: Float
    public let peakDB: Float

    public init(averageDB: Float, peakDB: Float) {
        self.averageDB = averageDB.isFinite ? min(0, max(-60, averageDB)) : -60
        self.peakDB = peakDB.isFinite ? min(0, max(-60, peakDB)) : -60
    }

    public var meterFraction: Double { Double((averageDB + 60) / 60) }
    public var isNearClipping: Bool { peakDB >= -1 }
    public static let silence = Self(averageDB: -60, peakDB: -60)
}

public final class AudioCaptureEngine: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        case began
        case paused
        case resumed
        case meter(AudioCaptureLevel, duration: Double)
        case ending
        case ended(URL, interruption: String?)
        case failed(String)
    }

    // Capture session setup, controls, notifications and delegate events all
    // converge on this queue. The caller receives only value snapshots.
    private let queue = DispatchQueue(label: "MacUtilityKit.AudioCapture", qos: .userInitiated)
    private var run: Run?

    private final class Run {
        let id = UUID()
        let session: AVCaptureSession
        let output: AVCaptureAudioFileOutput
        let url: URL
        let events: @Sendable (Event) -> Void
        var observers: [NSObjectProtocol] = []
        var timer: DispatchSourceTimer?
        var interruption: String?

        init(session: AVCaptureSession, output: AVCaptureAudioFileOutput,
             url: URL, events: @escaping @Sendable (Event) -> Void) {
            self.session = session
            self.output = output
            self.url = url
            self.events = events
        }
    }

    public static func devices() -> [AudioCaptureDevice] {
        discovery().devices.map { AudioCaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func start(deviceID: String?, at url: URL, events: @escaping @Sendable (Event) -> Void) {
        queue.async { [self] in
            do {
                try begin(deviceID: deviceID, at: url, events: events)
            } catch {
                events(.failed(error.localizedDescription))
            }
        }
    }

    public func pause() {
        queue.async { [self] in
            guard let output = run?.output, output.isRecording, !output.isRecordingPaused else { return }
            output.pauseRecording()
        }
    }

    public func resume() {
        queue.async { [self] in
            guard let output = run?.output, output.isRecordingPaused else { return }
            output.resumeRecording()
        }
    }

    public func stop() {
        queue.async { [self] in
            run?.output.stopRecording()
        }
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
    }

    private func begin(deviceID: String?, at url: URL, events: @escaping @Sendable (Event) -> Void) throws {
        guard run == nil else { throw ToolError.invalid("Finish the current recording before starting another.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw ToolError.invalid("Microphone access is unavailable.")
        }
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.invalid("Choose a new local recording file.")
        }
        let device: AVCaptureDevice?
        if let deviceID {
            device = Self.discovery().devices.first { $0.uniqueID == deviceID }
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw ToolError.invalid("Select a connected microphone.") }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioFileOutput()
        guard AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.m4a) else {
            throw ToolError.invalid("This Mac cannot record M4A audio.")
        }
        output.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 128_000]
        let session = AVCaptureSession()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw ToolError.invalid("This microphone cannot be used for recording.")
        }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        let active = Run(session: session, output: output, url: url, events: events)
        run = active
        observe(active, deviceID: device.uniqueID)
        session.startRunning()
        guard session.isRunning else {
            clear(active)
            throw ToolError.invalid("The microphone could not start recording.")
        }
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        let id = active.id
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll(id: id) }
        active.timer = timer
        timer.resume()
    }

    private func observe(_ active: Run, deviceID: String) {
        let id = active.id
        let center = NotificationCenter.default
        active.observers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) {
                [weak self] notification in
                guard (notification.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
                self?.interrupt(id: id, message: "The selected microphone disconnected.")
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: active.session, queue: nil) {
                [weak self] _ in self?.interrupt(id: id, message: "macOS interrupted microphone recording.")
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: active.session, queue: nil) {
                [weak self] notification in
                let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                self?.interrupt(id: id, message: detail ?? "The capture session encountered an error.")
            }
        ]
    }

    private func interrupt(id: UUID, message: String) {
        queue.async { [self] in
            guard let run, run.id == id, run.interruption == nil else { return }
            run.interruption = message
            run.events(.ending)
            run.output.stopRecording()
        }
    }

    private func poll(id: UUID) {
        guard let run, run.id == id, run.output.isRecording else { return }
        let duration = run.output.recordedDuration.seconds
        let level: AudioCaptureLevel
        if run.output.isRecordingPaused {
            level = .silence
        } else {
            let channels = run.output.connections.flatMap(\.audioChannels)
            level = AudioCaptureLevel(averageDB: channels.map(\.averagePowerLevel).max() ?? -60,
                                      peakDB: channels.map(\.peakHoldLevel).max() ?? -60)
        }
        run.events(.meter(level, duration: duration.isFinite ? max(0, duration) : 0))
    }

    private func emit(_ event: Event, for url: URL) {
        queue.async { [self] in
            guard let run, run.url == url else { return }
            run.events(event)
        }
    }

    private func clear(_ active: Run) {
        active.timer?.cancel()
        active.observers.forEach(NotificationCenter.default.removeObserver)
        run = nil
        if active.session.isRunning { active.session.stopRunning() }
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]
    ) {
        emit(.began, for: fileURL)
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput, didPauseRecordingTo fileURL: URL, from connections: [AVCaptureConnection]
    ) {
        emit(.paused, for: fileURL)
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput, didResumeRecordingTo fileURL: URL, from connections: [AVCaptureConnection]
    ) {
        emit(.resumed, for: fileURL)
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput, willFinishRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection], error: (any Error)?
    ) {
        emit(.ending, for: fileURL)
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: (any Error)?
    ) {
        let issue = error?.localizedDescription
        queue.async { [self] in
            guard let run, run.url == outputFileURL else { return }
            let interruption = run.interruption ?? issue
            clear(run)
            run.events(.ended(outputFileURL, interruption: interruption))
        }
    }
}
