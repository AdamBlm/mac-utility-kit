import AppKit
import AVFoundation
import Observation
import UtilityCore

@MainActor
@Observable
final class ScreenRecordingController {
    enum Phase: Equatable {
        case ready, selecting, authorizing, countdown(Int), starting, recording, pausing, paused, finishing
    }

    var settings = ScreenRecordingSettings()
    private(set) var phase = Phase.ready
    private(set) var sources: ScreenshotSources.Listings?
    private(set) var microphones: [AudioCaptureDevice] = []
    private(set) var permission = false
    private(set) var duration = 0.0
    private(set) var geometry: ScreenRecordingGeometry?
    private(set) var files: [ScreenRecordingFile] = []
    private(set) var saved: [URL: URL] = [:]
    private(set) var issue: String?
    private(set) var saving = false

    @ObservationIgnored private let selector = ScreenRegionSelector()
    @ObservationIgnored private let indicator = ScreenRecordingStatusItem()
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var session: ScreenRecordingSegment?
    @ObservationIgnored private var config: ScreenRecordingSettings?
    @ObservationIgnored private var parts: [ScreenRecordingFile] = []
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    var canStart: Bool {
        phase == .ready && permission && settings.source != nil && !saving
            && files.allSatisfy { saved[$0.url] != nil }
    }

    func refresh() async {
        permission = CGPreflightScreenCaptureAccess()
        microphones = AudioCaptureEngine.devices()
        guard permission else { sources = nil; return }
        do {
            let listings = try await ScreenshotSources.list()
            guard !Task.isCancelled else { return }
            sources = listings
            if settings.displayID == nil { settings.displayID = listings.displays.first?.id }
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }

    func requestAccess() {
        permission = ScreenCapturePermission.request()
        if permission {
            issue = nil
            Task {
                await refresh()
                if !permission {
                    issue = "Reopen Mac Utility Kit after enabling screen recording in System Settings."
                }
            }
        } else {
            issue = "Allow Screen & System Audio Recording in System Settings, then refresh the source list."
        }
    }

    func selectRegion() {
        guard phase == .ready, permission else { return }
        phase = .selecting
        issue = nil
        Task {
            defer { phase = .ready }
            guard let chosen = await selector.select() else { return }
            guard let display = chosen.displays.first(where: { $0.frame.contains(chosen.region) }),
                  let region = CaptureRegionGeometry.croppedRect(chosen.region, on: display.frame) else {
                issue = "Choose a region on one display."
                return
            }
            settings.region = .region(display.id, region.integral)
        }
    }

    func start() {
        guard canStart else { return }
        let selection = settings
        issue = nil
        phase = .authorizing
        operation = Task { await prepare(selection) }
    }

    func pause() {
        guard phase == .recording else { return }
        phase = .pausing
        indicatorState()
        Task { await completeSegment(remainingPaused: true, reason: nil) }
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .starting
        indicatorState()
        operation = Task { await beginSegment() }
    }

    func stop() {
        switch phase {
        case .countdown, .starting:
            operation?.cancel()
        case .recording:
            phase = .finishing
            indicatorState()
            Task { await completeSegment(remainingPaused: false, reason: nil) }
        case .paused:
            phase = .finishing
            indicatorState()
            Task { await finalize() }
        default: break
        }
    }

    func discard() {
        guard phase == .ready, !saving else { return }
        clearScratch()
        issue = nil
    }

    func save(_ file: ScreenRecordingFile, to url: URL) async {
        guard phase == .ready, !saving, files.contains(file) else { return }
        saving = true
        defer { saving = false }
        do {
            try await file.save(to: url)
            saved[file.url] = url
        } catch {
            issue = error.localizedDescription
        }
    }

    private func prepare(_ selection: ScreenRecordingSettings) async {
        var preparedFolder = false
        do {
            var prepared = selection
            if prepared.capturesMicrophone {
                try await authorizeMicrophone()
                let id = prepared.microphoneID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
                guard let id, AudioCaptureEngine.devices().contains(where: { $0.id == id }) else {
                    throw ToolError.invalid("Choose a connected microphone.")
                }
                prepared.microphoneID = id
            }
            try Task.checkCancellation()
            let path = FileManager.default.temporaryDirectory
                .appending(path: ".MacUtilityKit-Screen-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            clearScratch()
            folder = path
            config = prepared
            preparedFolder = true
            if prepared.countdown > 0 {
                for number in stride(from: min(10, prepared.countdown), through: 1, by: -1) {
                    phase = .countdown(number)
                    indicatorState()
                    try await Task.sleep(for: .seconds(1))
                }
            }
            try Task.checkCancellation()
            phase = .starting
            indicatorState()
            await beginSegment()
        } catch {
            if preparedFolder { clearScratch() }
            if !(error is CancellationError) { issue = error.localizedDescription }
            operation = nil
            indicator.remove()
            phase = .ready
        }
    }

    private func authorizeMicrophone() async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            throw ToolError.invalid("Open the Mac Utility Kit app bundle to record microphone audio.")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default: break
        }
        throw ToolError.invalid("Allow Mac Utility Kit in System Settings › Privacy & Security › Microphone, or turn off microphone audio.")
    }

    private func beginSegment() async {
        guard let folder, let config, let source = config.source else {
            issue = "Choose a recording source."
            phase = .ready
            indicator.remove()
            return
        }
        do {
            if let problem = unavailableSource(config) { throw ToolError.invalid(problem) }
            let url = folder.appending(path: "Segment-\(UUID().uuidString).mp4")
            let segment = try await ScreenRecordingSegment(source: source, settings: config, url: url, fixedGeometry: geometry)
            try Task.checkCancellation()
            session = segment
            try await segment.start { [weak self] in self?.interrupted() }
            try Task.checkCancellation()
            if let issue = segment.issue { throw ToolError.invalid(issue) }
            geometry = segment.geometry
            phase = .recording
            indicatorState()
            follow(segment, settings: config)
        } catch {
            let cancelled = error is CancellationError
            issue = cancelled ? nil : error.localizedDescription
            phase = .finishing
            indicatorState()
            await Task { await completeSegment(remainingPaused: false, reason: issue) }.value
        }
    }

    private func follow(_ segment: ScreenRecordingSegment, settings: ScreenRecordingSettings) {
        monitor?.cancel()
        monitor = Task { [weak self, weak segment] in
            var tick = 0
            while !Task.isCancelled, let self, let segment, self.phase == .recording {
                self.duration = self.parts.reduce(0) { $0 + $1.duration } + segment.duration
                self.indicatorState()
                if tick.isMultiple(of: 4), let problem = self.unavailableSource(settings) {
                    self.interrupted(reason: problem)
                    return
                }
                tick += 1
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
    }

    private func interrupted(reason: String? = nil) {
        guard phase == .recording else { return }
        phase = .finishing
        indicatorState()
        Task { await completeSegment(remainingPaused: false, reason: reason) }
    }

    private func completeSegment(remainingPaused: Bool, reason: String?) async {
        monitor?.cancel()
        monitor = nil
        var completionIssue = reason
        if let segment = session {
            completionIssue = await segment.stop() ?? completionIssue
            session = nil
            do {
                let file = try await ScreenRecordingFile.inspect(segment.url)
                parts.append(file)
            } catch {
                if !Task.isCancelled { completionIssue = completionIssue ?? error.localizedDescription }
            }
        }
        duration = parts.reduce(0) { $0 + $1.duration }
        issue = completionIssue
        if remainingPaused, completionIssue == nil {
            phase = .paused
            indicatorState()
        } else {
            phase = .finishing
            indicatorState()
            await finalize()
        }
    }

    private func finalize() async {
        defer {
            phase = .ready
            indicator.remove()
        }
        files = parts
        if parts.count > 1, let folder {
            do {
                let output = folder.appending(path: "Screen Recording.mp4")
                files = [try await ScreenRecordingFile.join(parts, to: output)]
            } catch {
                issue = [issue, "The segments could not be joined. Save the playable parts individually."].compactMap { $0 }.joined(separator: " ")
            }
        }
        if files.isEmpty {
            clearScratch()
        } else {
            let hasExpectedSound = !(config?.capturesSystemAudio == true || config?.capturesMicrophone == true)
                || files.contains { $0.audioTrackCount > 0 }
            if !hasExpectedSound {
                issue = [issue, "No audio track was captured."].compactMap { $0 }.joined(separator: " ")
            }
        }
    }

    private func unavailableSource(_ settings: ScreenRecordingSettings) -> String? {
        switch settings.source {
        case .display(let id), .region(let id, _):
            if CGDisplayIsActive(id) == 0 { return "The selected display disconnected." }
        case .window(let id):
            let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
            if (list ?? []).allSatisfy({ ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value != id }) {
                return "The selected window closed."
            }
        case nil: return "Choose a recording source."
        }
        if settings.capturesMicrophone, let id = settings.microphoneID,
           !AudioCaptureEngine.devices().contains(where: { $0.id == id }) {
            return "The selected microphone disconnected."
        }
        return nil
    }

    private func indicatorState() {
        let stop: () -> Void = { [weak self] in self?.stop() }
        switch phase {
        case .countdown(let seconds):
            indicator.update("● \(seconds)", actionTitle: nil, action: nil, onStop: stop)
        case .starting:
            indicator.update("● Starting", actionTitle: nil, action: nil, onStop: stop)
        case .recording:
            let clock = Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond))
            indicator.update("● \(clock)", actionTitle: "Pause", action: { [weak self] in self?.pause() }, onStop: stop)
        case .paused:
            indicator.update("Ⅱ Paused", actionTitle: "Resume", action: { [weak self] in self?.resume() }, onStop: stop)
        case .pausing, .finishing:
            indicator.update("● Saving", actionTitle: nil, action: nil, onStop: stop)
        default: indicator.remove()
        }
    }

    private func clearScratch() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        config = nil
        parts = []
        files = []
        saved = [:]
        duration = 0
        geometry = nil
    }
}
