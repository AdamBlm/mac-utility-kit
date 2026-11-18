import SwiftUI

@main
struct MacUtilityKitApp: App {
    @State private var keepAwakeController = KeepAwakeController()

    var body: some Scene {
        WindowGroup("Mac Utility Kit") { Workspace(keepAwakeController: keepAwakeController) }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .defaultSize(width: 940, height: 690)
    }
}
