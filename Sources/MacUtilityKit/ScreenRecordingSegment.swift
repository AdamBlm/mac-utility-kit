import AVFoundation
import Foundation
import ScreenCaptureKit
import UtilityCore

@MainActor
final class ScreenRecordingSegment {
    let url: URL
    let geometry: ScreenRecordingGeometry
    private let stream: SCStream
    private let output: SCRecordingOutput
    private let delegate: ScreenRecordingDelegate

    private(set) var hasStarted = false
    private(set) var hasFinished = false
    private(set) var issue: String?
    private var onInterruption: (() -> Void)?

    init(source: ScreenRecordingSettings.Source, settings: ScreenRecordingSettings, url: URL, fixedGeometry: ScreenRecordingGeometry?) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolError.invalid("Screen recording access is required.")
        }
        guard [15, 24, 30, 60].contains(settings.frameRate) else {
            throw ToolError.invalid("Choose a supported recording frame rate.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let region: CGRect?
        switch source {
        case .display(let id), .region(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ToolError.invalid("The selected display is disconnected.")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            if case .region(_, let selected) = source {
                let bounds = CGRect(origin: .zero, size: filter.contentRect.size)
                guard bounds.contains(selected) else {
                    throw ToolError.invalid("Adjust the region to fit the current display.")
                }
                region = selected
            } else {
                region = nil
            }
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id && $0.windowLayer == 0 }) else {
                throw ToolError.invalid("The selected window closed or is unavailable.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            region = nil
        }

        let dimensions = try fixedGeometry ?? ScreenRecordingGeometry(points: region?.size ?? filter.contentRect.size,
                                                     scale: Double(filter.pointPixelScale), resolution: settings.resolution)
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        configuration.queueDepth = 4
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.showMouseClicks = settings.showsClicks
        configuration.capturesAudio = settings.capturesSystemAudio
        configuration.captureMicrophone = settings.capturesMicrophone
        if settings.capturesMicrophone { configuration.microphoneCaptureDeviceID = settings.microphoneID }
        if let region { configuration.sourceRect = region }

        let file = SCRecordingOutputConfiguration()
        guard file.availableOutputFileTypes.contains(.mp4), file.availableVideoCodecTypes.contains(.h264) else {
            throw ToolError.invalid("This Mac cannot record H.264 to MP4.")
        }
        file.outputURL = url
        file.outputFileType = .mp4
        file.videoCodecType = .h264
        let delegate = ScreenRecordingDelegate()
        self.delegate = delegate
        self.output = SCRecordingOutput(configuration: file, delegate: delegate)
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        self.url = url
        self.geometry = dimensions

        delegate.receive = { [weak self] event in self?.receive(event) }
        try stream.addRecordingOutput(output)
    }

    var duration: Double {
        let seconds = output.recordedDuration.seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    func start(onInterruption: @escaping () -> Void) async throws {
        self.onInterruption = onInterruption
        try await stream.startCapture()
        for _ in 0..<80 where !hasStarted {
            if let issue { throw ToolError.invalid(issue) }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard hasStarted else { throw ToolError.invalid("ScreenCaptureKit did not start recording.") }
    }

    func stop() async -> String? {
        onInterruption = nil
        var stopIssue: String?
        do {
            try await stream.stopCapture()
        } catch {
            if !hasFinished { stopIssue = error.localizedDescription }
        }
        for _ in 0..<80 where !hasFinished {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !hasFinished {
            return issue ?? stopIssue ?? "ScreenCaptureKit could not finalize the segment."
        }
        return issue
    }

    private func receive(_ event: ScreenRecordingDelegate.Event) {
        switch event {
        case .started: hasStarted = true
        case .finished:
            hasFinished = true
            if let onInterruption {
                issue = issue ?? "ScreenCaptureKit ended the recording."
                onInterruption()
            }
        case .stoppedByUser:
            if let onInterruption {
                issue = "Screen recording was stopped from the system controls."
                onInterruption()
            }
        case .failed(let detail, let completesOutput):
            issue = issue ?? detail
            if completesOutput { hasFinished = true }
            onInterruption?()
        }
    }
}

private final class ScreenRecordingDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case started, finished, stoppedByUser, failed(String, completesOutput: Bool)
    }

    @MainActor var receive: ((Event) -> Void)?

    private func report(_ event: Event) {
        Task { @MainActor in receive?(event) }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { report(.started) }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { report(.finished) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        report(.failed(error.localizedDescription, completesOutput: true))
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        if (error as? SCStreamError)?.code == .userStopped { report(.stoppedByUser) }
        else { report(.failed(error.localizedDescription, completesOutput: false)) }
    }
}
