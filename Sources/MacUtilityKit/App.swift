import SwiftUI

@main
struct MacUtilityKitApp: App {
    @State private var keepAwakeController = KeepAwakeController()
    @State private var audioRecordingController = AudioRecordingController()

    var body: some Scene {
        WindowGroup("Mac Utility Kit") { Workspace(keepAwakeController: keepAwakeController, audioRecordingController: audioRecordingController) }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .defaultSize(width: 940, height: 690)
    }
}
