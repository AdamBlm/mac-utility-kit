import AppKit
import Observation
import SwiftUI
import UserNotifications
import UtilityCore

@MainActor
@Observable
final class ExportActivityCenter {
    static let shared = ExportActivityCenter()

    struct Status {
        let id: UUID
        let title: String
        let progress: Double?
    }

    private struct Job {
        let tool: Tool
        var progress: Double? = 0
        var phase: String?
        let activity: NSObjectProtocol
        let cancel: () -> Void
    }

    private var jobs: [UUID: Job] = [:]
    @ObservationIgnored private var dockView: ExportDockProgressView?

    var count: Int { jobs.count }

    var active: Status? {
        jobs.min(by: { $0.key.uuidString < $1.key.uuidString }).map {
            Status(id: $0.key, title: $0.value.phase ?? $0.value.tool.title, progress: $0.value.progress)
        }
    }

    func cancel(_ id: UUID) {
        jobs[id]?.cancel()
    }

    func start(_ tool: Tool, cancel: @escaping () -> Void) -> UUID {
        let id = UUID()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .idleSystemSleepDisabled],
            reason: "Processing with " + tool.title
        )
        jobs[id] = Job(tool: tool, activity: activity, cancel: cancel)
        refreshDock()
        return id
    }

    func update(_ id: UUID, fraction: Double?, phase: String? = nil) {
        guard fraction?.isFinite != false, jobs[id] != nil else { return }
        jobs[id]?.progress = fraction.map { min(1, max(0, $0)) }
        jobs[id]?.phase = phase
        refreshDock()
    }

    func finish(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        ProcessInfo.processInfo.endActivity(job.activity)
        refreshDock()
    }

    func cancelAll() {
        for job in jobs.values { job.cancel() }
    }

    func postCompletion(_ tool: Tool, report: JobReport) {
        postCompletion(tool, outputs: report.outputs.count, failures: report.failures.count, awaitingReview: report.videoReviews.count)
    }

    func postCompletion(_ tool: Tool, outputs count: Int, failures: Int = 0, awaitingReview: Int = 0) {
        guard !NSApp.isActive, UserDefaults.standard.bool(forKey: "exports.completionNotifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = tool.title
        content.body = if awaitingReview > 0 {
            "\(count) saved · \(awaitingReview) awaiting review · \(failures) failed. Open Mac Utility Kit for details."
        } else if failures == 0 {
            "\(count) output\(count == 1 ? "" : "s") saved."
        } else {
            "\(count) saved · \(failures) failed. Open Mac Utility Kit for details."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func refreshDock() {
        let tile = NSApp.dockTile
        guard !jobs.isEmpty else {
            if let dockView, tile.contentView === dockView { tile.contentView = nil }
            dockView = nil
            tile.display()
            return
        }
        let fractions = jobs.values.compactMap(\.progress)
        let view: ExportDockProgressView
        if let dockView {
            view = dockView
        } else {
            view = ExportDockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            dockView = view
            tile.contentView = view
        }
        view.icon.image = NSApp.applicationIconImage
        let indeterminate = fractions.count != jobs.count
        if view.progress.isIndeterminate != indeterminate {
            view.progress.isIndeterminate = indeterminate
            if indeterminate {
                view.progress.startAnimation(nil)
            } else {
                view.progress.stopAnimation(nil)
            }
        }
        if !indeterminate {
            view.progress.doubleValue = fractions.reduce(0, +) / Double(jobs.count)
        }
        tile.display()
    }
}

private final class ExportDockProgressView: NSView {
    let icon = NSImageView()
    let progress = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        addSubview(icon)
        addSubview(progress)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        icon.frame = bounds
        progress.frame = NSRect(x: bounds.width * 0.15, y: bounds.height * 0.11,
                                width: bounds.width * 0.7, height: 9)
    }
}

@MainActor
final class ExportTerminationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DraftRetention.shared.persist()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let center = ExportActivityCenter.shared
        guard center.count > 0 else { return .terminateNow }

        let prompt = NSAlert()
        prompt.messageText = "Exports are still running"
        prompt.informativeText = "Keep Mac Utility Kit open, or cancel the exports and quit after cleanup."
        prompt.addButton(withTitle: "Keep Open")
        prompt.addButton(withTitle: "Cancel Exports and Quit")
        guard prompt.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

        center.cancelAll()
        Task {
            let deadline = ContinuousClock.now + .seconds(8)
            while center.count > 0 && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: center.count == 0)
        }
        return .terminateLater
    }
}

struct ExportNotificationPreference: View {
    @AppStorage("exports.completionNotifications") private var enabled = false
    @State private var message: String?

    var body: some View {
        Toggle("Notify me when background exports finish", isOn: Binding(get: { enabled }, set: { value in
            if !value {
                enabled = false
                message = nil
                return
            }
            Task {
                do {
                    enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    message = enabled ? nil : "Notifications are disabled in System Settings."
                } catch {
                    message = error.localizedDescription
                }
            }
        }))
        if let message { Text(message).foregroundStyle(.secondary) }
    }
}
