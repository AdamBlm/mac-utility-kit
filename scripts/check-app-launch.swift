import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    print("Pass the path to the Mac Utility Kit app bundle.")
    exit(2)
}

let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = false

NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
    guard let app else {
        print(error?.localizedDescription ?? "Mac Utility Kit failed to launch.")
        exit(1)
    }

    DispatchQueue.main.async {
        waitForWorkspace(of: app, until: .now + 15)
    }
}

RunLoop.main.run()

@MainActor
private func waitForWorkspace(of app: NSRunningApplication, until deadline: Date) {
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    if let bounds = windows.compactMap({ workspaceBounds($0, for: app.processIdentifier) }).first {
        print("Mac Utility Kit opened a workspace window (\(bounds.width) × \(bounds.height)).")
        _ = app.terminate()
        waitForTermination(of: app, until: .now + 5, status: 0)
        return
    }
    guard !app.isTerminated, Date.now < deadline else {
        print("Mac Utility Kit did not open a workspace window.")
        if !app.isTerminated { _ = app.terminate() }
        waitForTermination(of: app, until: .now + 5, status: 1)
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        waitForWorkspace(of: app, until: deadline)
    }
}

private func workspaceBounds(_ window: [String: Any], for pid: pid_t) -> CGSize? {
    guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
          window[kCGWindowLayer as String] as? Int == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          let width = bounds["Width"], let height = bounds["Height"],
          width >= 700, height >= 450 else { return nil }
    return CGSize(width: width, height: height)
}

@MainActor
private func waitForTermination(
    of app: NSRunningApplication, until deadline: Date, status: Int32, forced: Bool = false
) {
    if app.isTerminated { exit(status) }
    if Date.now >= deadline {
        if forced {
            print("Mac Utility Kit did not exit after forced termination.")
            exit(1)
        }
        print("Mac Utility Kit did not quit after the launch check. Forcing termination.")
        _ = app.forceTerminate()
        waitForTermination(of: app, until: .now + 5, status: 1, forced: true)
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        waitForTermination(of: app, until: deadline, status: status, forced: forced)
    }
}
