import AppKit
import ScreenCaptureKit
import UtilityCore

@MainActor
enum ScreenshotSources {
    struct Source: Equatable, Identifiable {
        let id: UInt32
        let name: String
        let isUtilityWindow: Bool
    }

    struct Listings {
        let displays: [Source]
        let windows: [Source]
    }

    static func list() async throws -> Listings {
        let content = try await shareableContent()
        let displayNames = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (id.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        let displays = content.displays.map {
            Source(id: $0.displayID, name: displayNames[$0.displayID] ?? "Display", isUtilityWindow: false)
        }
        let windows: [Source] = content.windows.filter { availableWindow($0) }.map { window in
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let app = window.owningApplication?.applicationName ?? "Window"
            let dimensions = "\(Int(window.frame.width)) × \(Int(window.frame.height))"
            let name = title.flatMap { $0.isEmpty ? nil : "\(app) — \($0)" } ?? app
            return Source(id: window.windowID, name: name + " · " + dimensions,
                          isUtilityWindow: window.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier)
        }
        let sortedWindows = windows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Listings(displays: displays, windows: sortedWindows)
    }

    static func display(_ id: UInt32, showsCursor: Bool) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw ToolError.invalid("This display is no longer available. Refresh the source list.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await capture(filter, showsCursor: showsCursor)
    }

    static func window(_ id: UInt32, showsCursor: Bool) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id && availableWindow($0) }) else {
            throw ToolError.invalid("This window is unavailable. Restore it or refresh the source list.")
        }
        return try await capture(SCContentFilter(desktopIndependentWindow: window), showsCursor: showsCursor)
    }

    private static func shareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolError.invalid("Screen recording access is required.")
        }
        return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    private static func availableWindow(_ window: SCWindow) -> Bool {
        window.windowLayer == 0 && window.frame.width >= 60 && window.frame.height >= 60
    }

    private static func capture(_ filter: SCContentFilter, showsCursor: Bool) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        let width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        let height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        guard width > 0, height > 0, width <= 16_000, height <= 16_000, width * height <= 64_000_000 else {
            throw ToolError.invalid("This capture exceeds the supported image dimensions. Choose a smaller region.")
        }
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = showsCursor
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
