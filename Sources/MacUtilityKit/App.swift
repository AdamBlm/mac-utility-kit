import SwiftUI

@main
struct MacUtilityKitApp: App {
    @State private var keepAwakeController = KeepAwakeController()
    @State private var audioRecordingController = AudioRecordingController()
    @State private var screenRecordingController = ScreenRecordingController()

    var body: some Scene {
        WindowGroup("Mac Utility Kit") { Workspace(keepAwakeController: keepAwakeController, audioRecordingController: audioRecordingController, screenRecordingController: screenRecordingController) }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .defaultSize(width: 940, height: 690)
    }
}
