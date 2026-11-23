import Sparkle
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

    private static let updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
        updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        let _ = Self.updater
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
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .task {
                exportDelegate.attachFileRouting(to: launcherController)
                await VideoEngineSettings.shared.refresh()
                while !Task.isCancelled {
                    await VideoEngineSettings.shared.updateAutomatically()
                    do { try await Task.sleep(for: .seconds(3_600)) }
                    catch { return }
                }
            }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 940, height: 690)
        .commands { ImportFromDevicesCommands() }

        Window("Tool Launcher", id: LauncherController.launcherID) {
            ToolLauncherView(controller: launcherController)
        }
        .defaultSize(width: 520, height: 370)
        .handlesExternalEvents(matching: [])
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra("Mac Utility Kit", systemImage: "square.grid.2x2", isInserted: $launcher.menuBarEnabled) {
            LauncherMenu(controller: launcherController)
        }

        Settings {
            TabView {
                VStack {
                    LauncherSettingsView(controller: launcherController)
                    if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
                        Button("Check for App Updates…") { Self.updater.checkForUpdates(nil) }
                            .padding(.bottom)
                    }
                }
                    .tabItem { Label("General", systemImage: "gear") }
                VideoEngineSettingsView()
                    .tabItem { Label("Engines", systemImage: "shippingbox") }
            }
        }
    }
}
