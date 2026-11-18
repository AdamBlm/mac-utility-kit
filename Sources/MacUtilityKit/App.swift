import SwiftUI
import UtilityCore

@main
struct MacUtilityKitApp: App {
    @State private var keepAwakeController = KeepAwakeController()
    @State private var presentationModeController = PresentationModeController()
    @State private var clipboardHistoryController = ClipboardHistoryController()
    @State private var audioRecordingController = AudioRecordingController()
    @State private var screenRecordingController = ScreenRecordingController()

    var body: some Scene {
        WindowGroup("Mac Utility Kit") {
            Workspace(
                keepAwakeController: keepAwakeController,
                presentationModeController: presentationModeController,
                clipboardHistoryController: clipboardHistoryController,
                audioRecordingController: audioRecordingController,
                screenRecordingController: screenRecordingController
            )
        }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .defaultSize(width: 940, height: 690)
    }
}
