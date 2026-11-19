import SwiftUI
import UtilityCore

@main
struct MacUtilityKitApp: App {
    @NSApplicationDelegateAdaptor(ExportTerminationDelegate.self) private var exportDelegate
    @State private var keepAwakeController = KeepAwakeController()
    @State private var launcherController = LauncherController()
    @State private var presentationModeController = PresentationModeController()
    @State private var clipboardHistoryController = ClipboardHistoryController()
    @State private var audioRecordingController = AudioRecordingController()
    @State private var screenRecordingController = ScreenRecordingController()

    init() {
        _ = DraftRetention.shared
    }

    var body: some Scene {
        @Bindable var launcher = launcherController
        WindowGroup("Mac Utility Kit", id: LauncherController.workspaceID) {
            Workspace(
                keepAwakeController: keepAwakeController,
                launcherController: launcherController,
                presentationModeController: presentationModeController,
                clipboardHistoryController: clipboardHistoryController,
                audioRecordingController: audioRecordingController,
                screenRecordingController: screenRecordingController
            )
        }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 940, height: 690)
        .commands { ImportFromDevicesCommands() }

        Window("Tool Launcher", id: LauncherController.launcherID) {
            ToolLauncherView(controller: launcherController)
        }
        .defaultSize(width: 520, height: 370)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra("Mac Utility Kit", systemImage: "square.grid.2x2", isInserted: $launcher.menuBarEnabled) {
            LauncherMenu(controller: launcherController)
        }

        Settings {
            LauncherSettingsView(controller: launcherController)
        }
    }
}
